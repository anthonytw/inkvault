import CZlib
import Foundation
import InkVault

/// A read-only zip archive (PKWARE APPNOTE): central directory, stored and
/// deflated entries, and the zip64 extensions, so archives above 4 GiB or
/// with more than 65535 entries open too. No writing, no encryption, no
/// multi-disk archives.
///
/// An archive opened from a file reads entries on demand by seeking, so a
/// multi-gigabyte backup is never loaded whole.
public final class ZipArchive {
    /// One central-directory record.
    public struct Entry: Hashable, Sendable {
        /// Path inside the archive, `/`-separated. Directories end in `/`.
        public var path: String
        /// 0 stored, 8 deflate.
        public var method: UInt16
        /// CRC-32 of the uncompressed bytes.
        public var crc32: UInt32
        /// Size of the stored (possibly compressed) bytes.
        public var compressedSize: UInt64
        /// Size after decompression.
        public var uncompressedSize: UInt64
        /// Offset of the entry's local header from the start of the archive.
        public var localHeaderOffset: UInt64
        /// General-purpose flags (bit 0: encrypted).
        var flags: UInt16

        /// True for directory entries (path ends in `/`).
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    private enum Source {
        case data(Data)
        case file(FileHandle)
    }

    private let source: Source
    private let size: UInt64
    /// Every entry, in central-directory order.
    public let entries: [Entry]

    /// Default ceiling on one entry's uncompressed size (1 GiB).
    public static let defaultMaxEntrySize: UInt64 = 1 << 30

    /// Opens an archive held in memory.
    ///
    /// - Throws: `ImportError.zip` when no valid central directory is found.
    public init(data: Data) throws {
        source = .data(data)
        size = UInt64(data.count)
        entries = try Self.readDirectory(size: size) { off, count in try Self.slice(data, off, count) }
    }

    /// Opens an archive file for reading; entries are read lazily.
    ///
    /// - Throws: `ImportError.io` if the file cannot be opened,
    ///   `ImportError.zip` when no valid central directory is found.
    public init(url: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw ImportError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        let end: UInt64
        do { end = try handle.seekToEnd() } catch {
            throw ImportError.io("cannot size \(url.path): \(error.localizedDescription)")
        }
        source = .file(handle)
        size = end
        entries = try Self.readDirectory(size: end) { off, count in try Self.read(handle, off, count) }
    }

    deinit {
        if case .file(let h) = source { try? h.close() }
    }

    /// The entry at `path`, if any.
    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    /// The uncompressed bytes of `entry`, CRC-checked.
    ///
    /// - Throws: `ImportError.zip` for an encrypted entry, an unsupported
    ///   method, corrupt deflate data, a size or CRC mismatch, or an entry
    ///   larger than `maxSize`.
    public func read(_ entry: Entry, maxSize: UInt64 = ZipArchive.defaultMaxEntrySize) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ImportError.zip("\(entry.path): encrypted entries are not supported") }
        guard entry.uncompressedSize <= maxSize else {
            throw ImportError.zip("\(entry.path): \(entry.uncompressedSize) bytes exceeds the \(maxSize)-byte limit")
        }
        let header = try bytes(entry.localHeaderOffset, 30)
        guard header.u32(0) == 0x0403_4B50 else { throw ImportError.zip("\(entry.path): bad local header signature") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        let stored = try bytes(dataStart, entry.compressedSize)
        let out: Data
        switch entry.method {
        case 0: out = stored
        case 8:
            do { out = try Gzip.inflateRaw(stored, maxOutput: Int(entry.uncompressedSize)) } catch {
                throw ImportError.zip("\(entry.path): corrupt deflate data (\(error))")
            }
        default: throw ImportError.zip("\(entry.path): compression method \(entry.method) is not supported")
        }
        guard UInt64(out.count) == entry.uncompressedSize else {
            throw ImportError.zip("\(entry.path): size \(out.count), directory says \(entry.uncompressedSize)")
        }
        guard Self.crc32(out) == entry.crc32 else { throw ImportError.zip("\(entry.path): CRC mismatch") }
        return out
    }

    // MARK: - Directory

    private func bytes(_ offset: UInt64, _ count: UInt64) throws -> Data {
        switch source {
        case .data(let d): return try Self.slice(d, offset, count)
        case .file(let h): return try Self.read(h, offset, count)
        }
    }

    private static func slice(_ d: Data, _ offset: UInt64, _ count: UInt64) throws -> Data {
        guard offset <= UInt64(d.count), count <= UInt64(d.count) - offset else {
            throw ImportError.zip("read past end of archive")
        }
        let start = d.startIndex + Int(offset)
        return Data(d[start..<(start + Int(count))])
    }

    private static func read(_ h: FileHandle, _ offset: UInt64, _ count: UInt64) throws -> Data {
        guard count <= UInt64(Int.max) else { throw ImportError.zip("entry too large") }
        do {
            try h.seek(toOffset: offset)
            let d = try h.read(upToCount: Int(count)) ?? Data()
            guard d.count == Int(count) else { throw ImportError.zip("read past end of archive") }
            return d
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.io("read failed: \(error.localizedDescription)")
        }
    }

    private static func readDirectory(size: UInt64, read: (UInt64, UInt64) throws -> Data) throws -> [Entry] {
        // End of central directory: 22 bytes plus a comment of up to 65535.
        guard size >= 22 else { throw ImportError.zip("too short to be a zip archive") }
        let tailLength = min(size, 22 + 65535)
        let tailStart = size - tailLength
        let tail = try read(tailStart, tailLength)
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x0605_4B50, i + 22 + Int(tail.u16(i + 20)) <= tail.count { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw ImportError.zip("no end-of-central-directory record") }
        guard tail.u16(e + 4) == 0, tail.u16(e + 6) == 0 else { throw ImportError.zip("multi-disk archives are not supported") }
        var count = UInt64(tail.u16(e + 10))
        var cdSize = UInt64(tail.u32(e + 12))
        var cdOffset = UInt64(tail.u32(e + 16))

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // zip64 end-of-central-directory locator sits just before the EOCD.
            let locatorPos = tailStart + UInt64(e)
            guard locatorPos >= 20 else { throw ImportError.zip("missing zip64 locator") }
            let loc = try read(locatorPos - 20, 20)
            guard loc.u32(0) == 0x0706_4B50 else { throw ImportError.zip("missing zip64 locator") }
            let recOffset = loc.u64(8)
            let rec = try read(recOffset, 56)
            guard rec.u32(0) == 0x0606_4B50 else { throw ImportError.zip("bad zip64 end-of-central-directory record") }
            count = rec.u64(32)
            cdSize = rec.u64(40)
            cdOffset = rec.u64(48)
        }
        guard cdOffset <= size, cdSize <= size - cdOffset else { throw ImportError.zip("central directory out of range") }
        // Each record is at least 46 bytes, so `count` is bounded by the directory size.
        guard count <= cdSize / 46 + 1 else { throw ImportError.zip("entry count exceeds directory size") }
        let cd = try read(cdOffset, cdSize)

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else {
                throw ImportError.zip("bad central directory record at \(p)")
            }
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            var offset = UInt64(cd.u32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else {
                throw ImportError.zip("central directory record overruns the directory")
            }
            let nameBytes = cd.subdata(in: (cd.startIndex + nameStart)..<(cd.startIndex + nameStart + nameLen))
            let path = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)

            // zip64 extended information (0x0001): only the fields saturated above, in order.
            var x = nameStart + nameLen
            let extraEnd = x + extraLen
            while x + 4 <= extraEnd {
                let id = cd.u16(x), len = Int(cd.u16(x + 2))
                var f = x + 4
                let fieldEnd = min(f + len, extraEnd)
                if id == 0x0001 {
                    if usize == 0xFFFF_FFFF, f + 8 <= fieldEnd { usize = cd.u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= fieldEnd { csize = cd.u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= fieldEnd { offset = cd.u64(f); f += 8 }
                }
                x += 4 + len
            }
            entries.append(Entry(path: path, method: method, crc32: crc, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: offset, flags: flags))
            p = extraEnd + commentLen
        }
        return entries
    }

    // MARK: - zlib

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            var crc: uLong = CZlib.crc32(0, nil, 0)
            var base = raw.bindMemory(to: Bytef.self).baseAddress
            var left = raw.count
            while left > 0, let b = base {
                let n = min(left, Int(UInt32.max >> 1))
                crc = CZlib.crc32(crc, b, uInt(n))
                base = b + n
                left -= n
            }
            return UInt32(truncatingIfNeeded: crc)
        }
    }

}

// MARK: - Little-endian reads

extension Data {
    func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
