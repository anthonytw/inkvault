import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Atomic local writes: a half-written file never appears under its final name.
enum LocalFS {
    /// Same prefix the vault layer uses, so every listing ignores leftovers.
    static let tempPrefix = ".sempere-tmp-"

    /// Writes `data` to a temporary file next to `url`, flushes it, and moves it
    /// into place. With `replacing` false an existing file is never touched
    /// (`link(2)` fails with `EEXIST`) and the result is false.
    @discardableResult
    static func write(_ data: Data, to url: URL, replacing: Bool) throws -> Bool {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(tempPrefix + UUID().uuidString.lowercased())
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
        } catch {
            try? fm.removeItem(at: tmp)
            throw WebDAVError.io("write \(tmp.path): \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tmp) }
        let rc: Int32 = tmp.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return replacing ? rename(src, dst) : link(src, dst)
            }
        }
        if rc != 0 {
            if !replacing && errno == EEXIST { return false }
            throw WebDAVError.io("cannot place \(url.path): \(String(cString: strerror(errno)))")
        }
        syncDirectory(dir)
        return true
    }

    static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch {
            throw WebDAVError.io("remove \(url.path): \(error.localizedDescription)")
        }
        syncDirectory(url.deletingLastPathComponent())
    }

    private static func syncDirectory(_ dir: URL) {
        let fd = dir.withUnsafeFileSystemRepresentation { p -> Int32 in p.map { open($0, O_RDONLY) } ?? -1 }
        guard fd >= 0 else { return }
        _ = fsync(fd)
        _ = close(fd)
    }

    static func entries(_ dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do { return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() } catch {
            throw WebDAVError.io("list \(dir.path): \(error.localizedDescription)")
        }
    }
}
