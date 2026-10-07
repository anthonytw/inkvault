import Foundation
import Sempere
import SempereRender

/// Decrypted, verified attachments of the open vault, as private files
/// (docs/attachments.md §2 "Random access", §13): PDFKit and ImageIO need a
/// file, and decrypting a 40 MB PDF again for every redraw is slow. Files
/// live in the app's temporary directory (inside the container, encrypted by
/// Data Protection on iOS), mode 0600, never in a shared or synced place.
///
/// Least recently used files go once the cache holds more than `maxBytes` or
/// `maxFiles`, except files in use (`acquire` without its `release`). The
/// model clears it when the vault closes, locks or changes keys (`clear`).
///
/// A file is placed only once `fetch` returned: the fetch streams the blob
/// through the vault's checks (`Vault.streamBlob`: framing, padding, hash,
/// keyed name) and throws on any failure, so a file in the cache is always
/// whole, verified content (format.md §8.1.4).
actor BlobCache {
    /// Writes the verified content of `ref` (a blob of `note`) to
    /// `destination` (a new file), throwing on any failure.
    typealias Fetch = @Sendable (_ note: UUID, _ ref: BlobRef, _ destination: URL) async throws -> Void

    enum CacheError: Error, Equatable {
        /// The reference is not usable (bad hash or size).
        case invalidReference
        /// The fetched file is not the size the reference says.
        case sizeMismatch
        /// The cache was cleared while the blob was fetched.
        case cleared
    }

    nonisolated let root: URL
    nonisolated let maxBytes: Int64
    nonisolated let maxFiles: Int
    private let fetch: Fetch

    private struct Key: Hashable {
        var note: UUID
        var sha256: String
    }

    private struct Entry {
        var url: URL
        var size: Int64
        var lastUse: UInt64
        var pins: Int
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<URL, any Error>] = [:]
    private var tick: UInt64 = 0
    /// Bumped by `clear`: a fetch that finishes afterwards is thrown away.
    private var epoch = 0
    /// Set by `clear`: the vault this cache decrypts for is gone, so nothing
    /// is fetched again (a view may still hold the cache for a moment).
    private var closed = false
    /// Fetches started (for tests).
    private(set) var fetchCount = 0

    /// - Parameters:
    ///   - root: a folder of this cache alone; created on first use, deleted by `clear`.
    init(root: URL, maxBytes: Int64 = 512 << 20, maxFiles: Int = 256, fetch: @escaping Fetch) {
        self.root = root
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.fetch = fetch
    }

    /// The default folder for the caches of every model: one subfolder per cache.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereBlobs", isDirectory: true)
    }

    /// Removes caches left by an earlier run (killed before it could clear).
    nonisolated static func purgeStale(in folder: URL = BlobCache.folder, olderThan age: TimeInterval = 3600,
                                       now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if modified.map({ now.timeIntervalSince($0) > age }) ?? true { try? fm.removeItem(at: entry) }
        }
    }

    /// The file holding `ref`'s verified content, fetched if needed. The file
    /// stays until `release` is called as many times as `acquire` returned.
    func acquire(note: UUID, ref: BlobRef) async throws -> URL {
        guard !closed else { throw CacheError.cleared }
        guard ref.isValid else { throw CacheError.invalidReference }
        let key = Key(note: note, sha256: ref.sha256)
        if var entry = entries[key], FileManager.default.fileExists(atPath: entry.url.path) {
            tick &+= 1
            entry.lastUse = tick
            entry.pins += 1
            entries[key] = entry
            return entry.url
        }
        entries[key] = nil
        let task: Task<URL, any Error>
        if let running = inFlight[key] {
            task = running
        } else {
            let root = self.root, fetch = self.fetch
            fetchCount += 1
            task = Task.detached(priority: .userInitiated) {
                try Self.makeFolder(root)
                let name = ref.sha256 + "-" + note.uuidString.lowercased() + Self.pathExtension(ref)
                let final = root.appendingPathComponent(name)
                let tmp = root.appendingPathComponent(".tmp-" + UUID().uuidString)
                do {
                    try await fetch(note, ref, tmp)
                    let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
                    guard size == ref.size else { throw CacheError.sizeMismatch }
                    try? FileManager.default.removeItem(at: final)
                    try FileManager.default.moveItem(at: tmp, to: final)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                return final
            }
            inFlight[key] = task
        }
        let started = epoch
        let url: URL
        do {
            url = try await task.value
        } catch {
            if inFlight[key] == task { inFlight[key] = nil }
            throw error
        }
        if inFlight[key] == task { inFlight[key] = nil }
        guard started == epoch, !closed else {
            try? FileManager.default.removeItem(at: url)
            throw CacheError.cleared
        }
        tick &+= 1
        if var entry = entries[key] {
            // Another waiter on the same fetch placed it first.
            entry.pins += 1
            entry.lastUse = tick
            entries[key] = entry
        } else {
            entries[key] = Entry(url: url, size: ref.size, lastUse: tick, pins: 1)
        }
        evict()
        return url
    }

    /// Ends one use of `ref`'s file (after `acquire`).
    func release(note: UUID, ref: BlobRef) {
        let key = Key(note: note, sha256: ref.sha256)
        guard var entry = entries[key] else { return }
        entry.pins = max(0, entry.pins - 1)
        entries[key] = entry
        evict()
    }

    /// Whether `ref`'s file is in the cache now (no fetch).
    func contains(note: UUID, ref: BlobRef) -> Bool {
        entries[Key(note: note, sha256: ref.sha256)] != nil
    }

    /// Bytes held.
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    /// Files held.
    var count: Int { entries.count }

    /// Deletes every file (the vault closed, locked or changed keys). Fetches
    /// in flight are thrown away when they finish, and the cache fetches
    /// nothing more (`acquire` throws `cleared`): the model makes a new one.
    func clear() {
        closed = true
        epoch += 1
        entries = [:]
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        try? FileManager.default.removeItem(at: root)
    }

    /// Drops least recently used files that are not in use until the cache
    /// is within its limits.
    private func evict() {
        var bytes = totalBytes
        guard bytes > maxBytes || entries.count > maxFiles else { return }
        for (key, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where entry.pins == 0 {
            guard bytes > maxBytes || entries.count > maxFiles else { break }
            try? FileManager.default.removeItem(at: entry.url)
            entries[key] = nil
            bytes -= entry.size
        }
    }

    private static func makeFolder(_ root: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
    }

    /// A path extension readers may look at (PDF, images, audio).
    nonisolated static func pathExtension(_ ref: BlobRef) -> String {
        switch ref.type.lowercased() {
        case "application/pdf": return ".pdf"
        case "image/jpeg": return ".jpg"
        case "image/png": return ".png"
        case "image/heic": return ".heic"
        case "audio/mp4": return ".m4a"
        default: return ""
        }
    }

    /// Writes `produce`'s pieces to a new private file at `url` (mode 0600),
    /// removing it if `produce` throws: for `Fetch` implementations.
    nonisolated static func writeFile(_ url: URL, _ produce: ((Data) throws -> Void) throws -> Void) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            try produce { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Blobs already in a `BlobCache`, as the `BlobSource` the renderer reads
/// (`ItemRaster`): the files were verified when they were fetched; the
/// content is checked against the reference again on every read.
struct CachedBlobSource: BlobSource {
    /// Verified content files by SHA-256 (lowercase hex).
    var files: [String: URL]

    func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.contentTooLarge(limit: Int64(maxBytes)) }
        guard let url = files[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Int(ref.size) + 1) ?? Data()
        } catch {
            throw BlobError.missing(ref.sha256)
        }
        guard Int64(data.count) == ref.size, BlobRef(content: data, type: ref.type).sha256 == ref.sha256 else {
            throw BlobError.referenceMismatch
        }
        return data
    }

    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        guard let url = files[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        return try body(url)
    }
}
