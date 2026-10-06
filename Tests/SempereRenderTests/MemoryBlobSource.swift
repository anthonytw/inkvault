import Foundation
import Sempere

/// Blobs held in memory, keyed by content hash: a test double for
/// `BlobSource` (the vault's is `NoteBlobSource`). Verifies size and hash
/// like the vault does, so tests see the same failures.
struct MemoryBlobSource: BlobSource {
    var blobs: [String: Data]

    init(_ contents: [Data] = []) {
        blobs = [:]
        for c in contents { blobs[BlobRef(content: c, type: "").sha256] = c }
    }

    func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.tooLarge(ref.size) }
        guard let d = blobs[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        guard Int64(d.count) == ref.size, BlobRef(content: d, type: ref.type).sha256 == ref.sha256 else {
            throw BlobError.referenceMismatch
        }
        return d
    }

    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        let d = try data(for: ref, maxBytes: Int(BlobRef.maxSize))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-memblob-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("content")
        try d.write(to: url)
        return try body(url)
    }
}
