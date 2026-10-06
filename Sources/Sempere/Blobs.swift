import Age
import Crypto
import Foundation

// MARK: - Blob reading (format.md §8.1.2–§8.1.4)
//
// The read side of the per-note blob store: names, framing and verification.
// Exporters read image (and later PDF and audio) bytes through `BlobSource`.
// Writing blobs, rewrapping them on a recipient change and collecting them
// are task B2 (docs/attachments.md §14); until it lands, no public API writes
// a blob, because a recipient change would not yet rewrap them.

/// Where a renderer gets the verified bytes of a note's blobs
/// (docs/attachments.md §10). A per-note view of a vault conforms
/// (`Vault.blobSource(note:)`); tests and the app may supply their own.
public protocol BlobSource: Sendable {
    /// The content of `ref`, verified against its `sha256` and `size`.
    ///
    /// - Throws: `BlobError.tooLarge` when `ref.size` exceeds `maxBytes`
    ///   (before reading anything), else `BlobError` or the source's own
    ///   errors when the blob is missing, unreadable or invalid.
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data
    /// Runs `body` with a private temporary file holding the verified
    /// content of `ref`, deleted afterwards (for content too large to hold
    /// in memory, format.md §8.1.4).
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T
}

/// Why a blob could not be read. Renderers draw a placeholder for each
/// (format.md §8.5.2).
public enum BlobError: Error, Equatable, Sendable {
    /// No file for the reference in the note's `att/` (under the current
    /// secret, nor the previous one during a rewrap).
    case missing(sha256: String)
    /// The content is larger than the caller accepts.
    case tooLarge(size: Int64, limit: Int)
    /// The file decrypts but is not a valid blob for the reference: bad
    /// framing, non-zero padding, another hash or length, or content that
    /// does not hash to the header's value.
    case invalid(String)
    /// The file could not be read or decrypted.
    case unreadable(String)
}

extension BlobError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing(let h): return "attachment \(h.prefix(12))… is missing"
        case .tooLarge(let size, let limit): return "attachment of \(size) bytes is larger than the \(limit)-byte limit"
        case .invalid(let s): return "attachment is invalid (\(s))"
        case .unreadable(let s): return "attachment cannot be read (\(s))"
        }
    }
}

/// The plaintext framing of a blob file (format.md §8.1.3).
public enum BlobFraming {
    /// `INKB`.
    public static let magic: [UInt8] = [0x49, 0x4E, 0x4B, 0x42]
    public static let version: UInt8 = 1
    /// Magic, version, SHA-256, length.
    public static let headerSize = 45

    /// The 45-byte header for content with `sha256` (32 raw bytes) and `length`.
    public static func header(sha256: Data, length: Int64) -> Data {
        var h = Data(magic)
        h.append(version)
        h.append(sha256)
        for i in (0..<8).reversed() { h.append(UInt8(truncatingIfNeeded: UInt64(length) >> (8 * UInt64(i)))) }
        return h
    }

    /// Padmé (format.md §8.1.3): the padded plaintext length for `n` bytes.
    public static func padme(_ n: Int) -> Int {
        guard n >= 2 else { return n }
        let e = Int.bitWidth - 1 - n.leadingZeroBitCount            // floor(log2 n)
        let s = Int.bitWidth - e.leadingZeroBitCount                 // floor(log2 e) + 1
        let z = e - s
        guard z > 0 else { return n }
        let mask = (1 << z) - 1
        return (n + mask) & ~mask
    }
}

extension Vault {
    /// The `att/` folder of a note.
    func attachmentsURL(note: UUID) -> URL {
        notesURL.appendingPathComponent(note.uuidString.lowercased()).appendingPathComponent("att")
    }

    /// `blobName` (format.md §8.1.2) of content with this SHA-256 (32 raw
    /// bytes) under `secret`: 64 lowercase hex digits.
    static func blobName(sha256: Data, secret: VaultSecret) -> String {
        var message = Data("sempere/1".utf8)
        message.append(0)
        message.append(contentsOf: Array("blob".utf8))
        message.append(0)
        message.append(sha256)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: secret.key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// `blobName` (format.md §8.1.2) under the current vault secret.
    ///
    /// - Throws: `VaultError.locked`.
    public func blobName(sha256: Data) throws -> String {
        Self.blobName(sha256: sha256, secret: try requireSecret())
    }

    /// The file of `ref` in `note`'s `att/`: by its name under the current
    /// secret, else (while a rewrap journal exists) under the previous one.
    func blobFile(note: UUID, _ ref: BlobRef) throws -> URL {
        let secret = try requireReadable()
        guard ref.isValid, let digest = ref.digest else { throw BlobError.invalid("bad reference") }
        let dir = attachmentsURL(note: note)
        let kind = ref.kind.rawValue
        var secrets = [secret]
        if let previousSecret, pendingRewrap { secrets.append(previousSecret) }
        for s in secrets {
            let url = dir.appendingPathComponent("\(Self.blobName(sha256: digest, secret: s)).\(kind).age")
            if FileIO.exists(url) { return url }
        }
        throw BlobError.missing(sha256: ref.sha256)
    }

    /// Streams `ref`'s file through `sink` (the content, in order) and
    /// verifies it completely: framing, the reference's hash and length,
    /// zero padding, the content hash and the end of the age stream. `sink`
    /// sees unverified bytes: callers discard what they got unless this
    /// returns normally.
    func streamBlob(note: UUID, _ ref: BlobRef, _ sink: (Data) throws -> Void) throws {
        try requireMigrated()
        let url = try blobFile(note: note, ref)
        let handle: FileHandle
        do { handle = try BoundedRead.openRegularFile(url) } catch { throw BlobError.unreadable("\(error)") }
        defer { try? handle.close() }
        // A blob file is at most 1 GiB of content plus framing and age overhead.
        var consumed = 0
        let decryptor: AgeDecryptor
        do {
            decryptor = try AgeDecryptor(identities: identities) { n in
                let want = min(n, BoundedRead.maxBlobFileBytes + 1 - consumed)
                guard want > 0 else { throw BlobError.tooLarge(size: Int64(consumed), limit: BoundedRead.maxBlobFileBytes) }
                let d = try handle.read(upToCount: want) ?? Data()
                consumed += d.count
                return d
            }
        } catch let e as BlobError { throw e } catch { throw BlobError.unreadable("\(error)") }

        var header = Data()
        var remaining = ref.size
        var hasher = SHA256()
        var headerChecked = false
        do {
            while let chunk = try decryptor.next() {
                var c = chunk[...]
                if !headerChecked {
                    let need = BlobFraming.headerSize - header.count
                    header.append(c.prefix(need))
                    c = c.dropFirst(need)
                    guard header.count == BlobFraming.headerSize else { continue }
                    let expected = BlobFraming.header(sha256: ref.digest ?? Data(), length: ref.size)
                    guard Array(header.prefix(5)) == BlobFraming.magic + [BlobFraming.version] else {
                        throw BlobError.invalid("not a version-1 blob")
                    }
                    guard header == expected else { throw BlobError.invalid("header names other content") }
                    headerChecked = true
                }
                if remaining > 0 {
                    let take = Int(min(Int64(c.count), remaining))
                    let content = Data(c.prefix(take))
                    hasher.update(data: content)
                    try sink(content)
                    remaining -= Int64(take)
                    c = c.dropFirst(take)
                }
                guard c.allSatisfy({ $0 == 0 }) else { throw BlobError.invalid("non-zero padding") }
            }
        } catch let e as BlobError { throw e } catch { throw BlobError.unreadable("\(error)") }
        guard headerChecked else { throw BlobError.invalid("shorter than its header") }
        guard remaining == 0 else { throw BlobError.invalid("content shorter than its length") }
        let digest = Data(hasher.finalize())
        guard digest == ref.digest else { throw BlobError.invalid("content does not match its hash") }
    }

    /// The verified content of `ref` in `note` (format.md §8.1.4).
    ///
    /// - Throws: `BlobError` (`.tooLarge` before reading when `ref.size`
    ///   exceeds `maxBytes`); `VaultError.locked`, `.noIdentities`,
    ///   `.legacyVault`.
    public func readBlob(note: UUID, _ ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.tooLarge(size: ref.size, limit: maxBytes) }
        var out = Data()
        out.reserveCapacity(Int(max(ref.size, 0)))
        try streamBlob(note: note, ref) { out.append($0) }
        return out
    }

    /// Runs `body` with a private temporary file (mode 0600) holding the
    /// verified content of `ref`; the file is deleted afterwards. Memory use
    /// is one age chunk, whatever the blob's size.
    public func withBlobFile<T>(note: UUID, _ ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        try withPrivateTemporaryFile(writing: { write in try streamBlob(note: note, ref) { try write($0) } }, body)
    }

    /// A `BlobSource` for one note of this vault.
    public func blobSource(note: UUID) -> VaultBlobSource { VaultBlobSource(vault: self, note: note) }

    /// Writes `content` as a blob of `note` (framing, Padmé, age to the
    /// vault's recipients, atomic, never replacing) and returns its
    /// reference. Internal and for tests only until task B2 adds the public
    /// writer together with the blob rewrap of recipient changes.
    func writeBlobForTesting(note: UUID, _ content: Data, type: String) throws -> BlobRef {
        try requireMigrated()
        let secret = try requireSecret()
        let ref = BlobRef(content: content, type: type)
        guard let digest = ref.digest else { throw BlobError.invalid("bad reference") }
        var plain = BlobFraming.header(sha256: digest, length: ref.size)
        plain.append(content)
        plain.append(Data(count: BlobFraming.padme(plain.count) - plain.count))
        let dir = attachmentsURL(note: note)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Self.blobName(sha256: digest, secret: secret)).\(ref.kind.rawValue).age")
        if !FileIO.exists(url) {
            try FileIO.writeAtomically(try Self.encrypt(plain, to: try ageRecipients()), to: url, replacing: false)
        }
        return ref
    }
}

/// A note's blobs in a vault, as a `BlobSource`.
public struct VaultBlobSource: BlobSource {
    public let vault: Vault
    public let note: UUID

    public func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        try vault.readBlob(note: note, ref, maxBytes: maxBytes)
    }

    public func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        try vault.withBlobFile(note: note, ref, body)
    }
}

/// Blobs held in memory, keyed by content hash: for tests, and for callers
/// that already hold the bytes (an import being previewed).
public struct MemoryBlobSource: BlobSource {
    public var blobs: [String: Data]

    public init(_ contents: [Data] = []) {
        blobs = [:]
        for c in contents { blobs[BlobRef(content: c, type: "").sha256] = c }
    }

    public func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.tooLarge(size: ref.size, limit: maxBytes) }
        guard let d = blobs[ref.sha256] else { throw BlobError.missing(sha256: ref.sha256) }
        guard Int64(d.count) == ref.size, BlobRef(content: d, type: ref.type).sha256 == ref.sha256 else {
            throw BlobError.invalid("content does not match its reference")
        }
        return d
    }

    public func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        let d = try data(for: ref, maxBytes: Int(BlobRef.maxSize))
        return try withPrivateTemporaryFile(writing: { write in try write(d) }, body)
    }
}

/// Runs `body` with a temporary file only this user can read (mode 0600, in
/// a fresh 0700 directory) holding what `writing` wrote, and deletes it
/// afterwards, whether `writing` or `body` throws or not. Blob content is
/// plaintext: it must never land in a world-readable file.
func withPrivateTemporaryFile<T>(writing: (_ write: (Data) throws -> Void) throws -> Void,
                                 _ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sempere-blob-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("content")
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let h = FileHandle(forWritingAtPath: file.path) else { throw BlobError.unreadable("cannot create a temporary file") }
    do {
        try writing { try h.write(contentsOf: $0) }
        try h.close()
    } catch {
        try? h.close()
        throw error
    }
    return try body(file)
}
