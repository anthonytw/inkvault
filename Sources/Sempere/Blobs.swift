import Age
import Crypto
import Foundation

/// How a renderer gets a note's blobs (`docs/attachments.md` §10): as
/// verified bytes, or as a verified temporary plaintext file for large ones.
/// A source is per note: references resolve only inside the note that holds
/// them (format.md §8.1.1).
public protocol BlobSource: Sendable {
    /// The blob's content, verified. Throws when it is larger than `maxBytes`.
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data
    /// Runs `body` with a private temporary file holding the verified
    /// content; the file is deleted afterwards.
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T
}

/// Errors reading a blob (format.md §8.1.4). Each makes the item a
/// placeholder (§8.5.2).
public enum BlobError: Error, Equatable, Sendable {
    /// The reference's `sha256` or `size` is malformed.
    case invalidReference
    /// No blob file for the reference (its expected file name).
    case missing(String)
    /// The file does not decrypt or fails a check (what failed).
    case invalid(String)
    /// The content is larger than the caller accepts.
    case tooLarge(size: Int64, limit: Int)
}

extension BlobError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidReference: return "the attachment reference is malformed"
        case .missing(let name): return "attachment \(name) is missing"
        case .invalid(let why): return "attachment is invalid: \(why)"
        case .tooLarge(let size, let limit): return "attachment of \(size) bytes is larger than the limit of \(limit)"
        }
    }
}

/// Blob file layout (format.md §8.1.2–§8.1.3).
public enum BlobFile {
    /// `INKB`.
    public static let magic = Data("INKB".utf8)
    /// Header: magic, version, SHA-256, content length.
    public static let headerSize = 45

    /// `padme(n)`: the padded plaintext length (format.md §8.1.3).
    public static func padme(_ n: Int) -> Int {
        guard n >= 2 else { return n }
        let e = Int.bitWidth - 1 - n.leadingZeroBitCount   // floor(log2 n)
        let s = Int.bitWidth - e.leadingZeroBitCount       // floor(log2 e) + 1
        let z = e - s
        let mask = (1 << z) - 1
        return (n + mask) & ~mask
    }

    /// `blobName` for a content hash under a vault secret.
    public static func name(sha256: Data, secret: VaultSecret) -> String {
        var message = Data("sempere/1".utf8)
        message.append(0)
        message.append(contentsOf: "blob".utf8)
        message.append(0)
        message.append(sha256)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret.bytes))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// The plaintext of a blob file: header, content, zero padding to `padme`.
    static func plaintext(content: Data) -> Data {
        var out = magic
        out.append(1)
        out.append(Data(SHA256.hash(data: content)))
        var length = UInt64(content.count).bigEndian
        out.append(Data(bytes: &length, count: 8))
        out.append(content)
        out.append(Data(count: padme(out.count) - out.count))
        return out
    }
}

extension Vault {
    static let blobDirectoryName = "att"

    /// `blobName` for `sha256` (32 raw bytes) under the current vault secret.
    ///
    /// - Throws: `VaultError.locked`; `BlobError.invalidReference` for a
    ///   hash that is not 32 bytes.
    public func blobName(sha256: Data) throws -> String {
        guard sha256.count == 32 else { throw BlobError.invalidReference }
        return BlobFile.name(sha256: sha256, secret: try requireSecret())
    }

    /// The blob's content, verified (format.md §8.1.4).
    ///
    /// - Throws: `BlobError.tooLarge` when `ref.size > maxBytes` (before
    ///   reading), `.missing`, `.invalid`, `.invalidReference`;
    ///   `VaultError.locked`, `.noIdentities`, `.legacyVault`.
    public func readBlob(note: UUID, _ ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.isValid else { throw BlobError.invalidReference }
        guard ref.size <= Int64(maxBytes) else { throw BlobError.tooLarge(size: ref.size, limit: maxBytes) }
        var out = Data()
        try streamBlob(note: note, ref) { out.append($0) }
        return out
    }

    /// Runs `body` with a private temporary file of the verified content
    /// (written and checked in full before `body` runs), deleted afterwards.
    /// Memory use is one age chunk, whatever the blob's size.
    ///
    /// - Throws: as `readBlob`, plus `VaultError.io` for the temporary file.
    public func withBlobFile<T>(note: UUID, _ ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        guard ref.isValid else { throw BlobError.invalidReference }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sempere-blob-\(UUID().uuidString.lowercased())")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw VaultError.io("cannot create a temporary directory: \(error.localizedDescription)") }
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("content")
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else {
            throw VaultError.io("cannot create a temporary file in \(dir.path)")
        }
        do {
            defer { try? handle.close() }
            try streamBlob(note: note, ref) { chunk in
                do { try handle.write(contentsOf: chunk) } catch { throw VaultError.io("write \(file.path): \(error)") }
            }
        }
        return try body(file)
    }

    /// A `BlobSource` over this note's `att/`.
    public func blobSource(note: UUID) -> VaultBlobSource { VaultBlobSource(vault: self, note: note) }

    /// The file for `ref` in the note's `att/`: under the current secret, or
    /// during an unfinished rewrap under the previous one (format.md §8.1.5).
    func blobURL(note: UUID, _ ref: BlobRef) throws -> URL {
        guard let digest = ref.digest else { throw BlobError.invalidReference }
        let dir = noteURL(note).appendingPathComponent(Self.blobDirectoryName)
        let file = "\(try blobName(sha256: digest)).\(ref.kind.rawValue).age"
        let url = dir.appendingPathComponent(file)
        if FileIO.exists(url) { return url }
        if let previousSecret {
            let old = dir.appendingPathComponent("\(BlobFile.name(sha256: digest, secret: previousSecret)).\(ref.kind.rawValue).age")
            if FileIO.exists(old) { return old }
        }
        throw BlobError.missing(file)
    }

    /// Decrypts and checks the blob, handing the content to `sink` chunk by
    /// chunk. Callers must not use what `sink` received unless this returns:
    /// the content hash is known only at the end.
    func streamBlob(note: UUID, _ ref: BlobRef, _ sink: (Data) throws -> Void) throws {
        try requireMigrated()
        _ = try requireReadable()
        guard ref.isValid, let digest = ref.digest else { throw BlobError.invalidReference }
        let url = try blobURL(note: note, ref)
        let handle = try BoundedRead.openRegularFile(url)
        defer { try? handle.close() }
        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd(); try handle.seek(toOffset: 0) } catch {
            throw VaultError.io("read \(url.path): \(error)")
        }
        guard fileSize <= UInt64(BoundedRead.maxBlobFileBytes) else {
            throw VaultError.fileTooLarge(url.path, limit: BoundedRead.maxBlobFileBytes)
        }
        let decryptor: AgeDecryptor
        do { decryptor = try AgeDecryptor(reading: handle, identities: identities) } catch {
            throw BlobError.invalid("cannot decrypt (\(error))")
        }
        var header = Data()
        var remaining = UInt64(ref.size)
        var hasher = SHA256()
        while true {
            let next: Data?
            do { next = try decryptor.next() } catch { throw BlobError.invalid("cannot decrypt (\(error))") }
            guard let chunk = next else { break }
            var rest = chunk[...]
            if header.count < BlobFile.headerSize {
                let take = min(BlobFile.headerSize - header.count, rest.count)
                header.append(contentsOf: rest.prefix(take))
                rest = rest.dropFirst(take)
                if header.count == BlobFile.headerSize { try Self.checkHeader(header, ref: ref, digest: digest) }
            }
            guard !rest.isEmpty else { continue }
            let n = Int(min(UInt64(rest.count), remaining))
            if n > 0 {
                let content = Data(rest.prefix(n))
                hasher.update(data: content)
                try sink(content)
                remaining -= UInt64(n)
                rest = rest.dropFirst(n)
            }
            guard rest.allSatisfy({ $0 == 0 }) else { throw BlobError.invalid("non-zero padding") }
        }
        guard header.count == BlobFile.headerSize, remaining == 0 else { throw BlobError.invalid("truncated") }
        guard Data(hasher.finalize()) == digest else { throw BlobError.invalid("content hash mismatch") }
    }

    static func checkHeader(_ h: Data, ref: BlobRef, digest: Data) throws {
        let b = [UInt8](h)
        guard Data(b[0..<4]) == BlobFile.magic else { throw BlobError.invalid("bad magic") }
        guard b[4] == 1 else { throw BlobError.invalid("unknown blob version \(b[4])") }
        guard Data(b[5..<37]) == digest else { throw BlobError.invalid("header hash differs from the reference") }
        var length: UInt64 = 0
        for x in b[37..<45] { length = length << 8 | UInt64(x) }
        guard length == UInt64(ref.size) else { throw BlobError.invalid("header length differs from the reference") }
    }

    /// Writes `content` as a blob of `note` (format.md §8.1.4 steps 1–3,
    /// without the reuse check) and returns its reference.
    ///
    /// Test seam: the public, streaming writer with reuse and the rest of
    /// the blob store is attachments task B2.
    func writeBlob(note: UUID, _ content: Data, type: String) throws -> BlobRef {
        try requireMigrated()
        let ref = BlobRef(content: content, type: type)
        let dir = noteURL(note).appendingPathComponent(Self.blobDirectoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let digest = ref.digest else { throw BlobError.invalidReference }
        let url = dir.appendingPathComponent("\(try blobName(sha256: digest)).\(ref.kind.rawValue).age")
        if FileIO.exists(url) { return ref }
        let sealed = try Self.encrypt(BlobFile.plaintext(content: content), to: try ageRecipients())
        try FileIO.writeAtomically(sealed, to: url, replacing: false)
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
