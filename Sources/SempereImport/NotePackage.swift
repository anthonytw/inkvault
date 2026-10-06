import Foundation
import Sempere

/// The files of one Notability `.note` package: a zip (the usual form) or
/// an unzipped package directory. Paths are `/`-separated and relative to the
/// package root.
public struct NotePackage {
    /// Every file path in the package.
    public let paths: [String]
    private let reader: (String) throws -> Data

    /// Wraps a package already opened as a zip.
    public init(zip: ZipArchive) {
        let files = zip.entries.filter { !$0.isDirectory }
        paths = files.map(\.path)
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        reader = { path in
            guard let e = byPath[path] else { throw ImportError.notability("no \(path) in package") }
            return try zip.read(e)
        }
    }

    /// Reads a package from `.note` file bytes (a zip).
    ///
    /// - Throws: `ImportError.zip` when the bytes are not a zip.
    public init(data: Data) throws {
        self.init(zip: try ZipArchive(data: data))
    }

    /// Reads an unzipped package directory.
    ///
    /// - Throws: `ImportError.io` when the directory cannot be listed.
    public init(directory: URL) throws {
        let base = directory.standardizedFileURL.pathComponents
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ImportError.io("cannot list \(directory.path)")
        }
        var found: [String] = []
        for case let f as URL in walker {
            // Regular files only: no symlinks (a shared package must not pull
            // in files from elsewhere), devices or FIFOs.
            let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            found.append(f.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/"))
        }
        paths = found.sorted()
        reader = { path in
            try Self.readFile(directory.appendingPathComponent(path), maxSize: ZipArchive.defaultMaxEntrySize)
        }
    }

    /// The bytes of `path`.
    public func read(_ path: String) throws -> Data { try reader(path) }

    /// Reads a whole file, refusing one larger than `maxSize` before
    /// allocating for it (a file in a shared folder can be any size).
    static func readFile(_ url: URL, maxSize: UInt64) throws -> Data {
        do {
            let h = try BoundedRead.openRegularFile(url)
            defer { try? h.close() }
            let data = try h.read(upToCount: Int(min(maxSize, UInt64(Int.max - 1))) + 1) ?? Data()
            guard UInt64(data.count) <= maxSize else {
                throw ImportError.io("\(url.path) is larger than the \(maxSize)-byte limit")
            }
            return data
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// True when the package holds `path`.
    public func contains(_ path: String) -> Bool { paths.contains(path) }
}
