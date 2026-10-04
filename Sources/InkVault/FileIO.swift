import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Small portable filesystem helpers (Foundation + POSIX `rename(2)`), so the
/// vault layer behaves the same on Apple platforms and Linux.
enum FileIO {
    static var fm: FileManager { FileManager.default }

    /// Prefix of in-flight temporary files. They start with a dot and carry no
    /// `.age` suffix, so every listing ignores them as unknown files.
    static let tempPrefix = ".inkvault-tmp-"

    /// Writes `data` to `url` atomically: a temporary file in the same
    /// directory is written and flushed to disk, then renamed into place.
    /// Readers see either nothing (or the old file) or the complete new one.
    ///
    /// - Parameter replacing: when false the call refuses an existing
    ///   destination with `VaultError.alreadyExists`. The check happens right
    ///   before the rename; a writer racing on the very same name is outside
    ///   the format's model (names embed a per-device sequence number).
    static func writeAtomically(_ data: Data, to url: URL, replacing: Bool) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(tempPrefix + UUID().uuidString.lowercased())
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
        } catch {
            try? fm.removeItem(at: tmp)
            throw VaultError.io("write \(tmp.path): \(error)")
        }
        if !replacing && exists(url) {
            try? fm.removeItem(at: tmp)
            throw VaultError.alreadyExists(url.path)
        }
        let rc = tmp.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return rename(src, dst)
            }
        }
        guard rc == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw VaultError.io("rename to \(url.path): errno \(code)")
        }
    }

    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw VaultError.io("read \(url.path): \(error)") }
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// Entry names in `dir`, sorted; empty when it does not exist.
    static func entries(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func createDirectory(_ url: URL) throws {
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch {
            throw VaultError.io("mkdir \(url.path): \(error)")
        }
    }

    static func remove(_ url: URL) throws {
        do { try fm.removeItem(at: url) } catch { throw VaultError.io("remove \(url.path): \(error)") }
    }
}
