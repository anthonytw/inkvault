import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Installing a model the user picked in Files: a folder, or a stored zip of
/// one (MathModelImport). Uses the tiny random fixture model.
final class MathModelImportTests: XCTestCase {
    func tinyFolder() throws -> URL { try T.fixtureURL("math-tiny") }

    func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A zip of `folder`'s files (and `extra` entries), every entry stored; `method` 8 marks them deflated (unsupported).
    func zip(of folder: URL, prefix: String = "", extra: [(String, Data)] = [], method: UInt16 = 0) throws -> URL {
        var items: [(String, Data)] = extra
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(url.path.dropFirst(folder.path.count + 1))
            items.append((prefix + rel, try Data(contentsOf: url)))
        }
        var body = Data(), directory = Data()
        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 255)); d.append(UInt8(v >> 8 & 255)) }
        func put32(_ d: inout Data, _ v: Int) { put16(&d, v & 0xFFFF); put16(&d, v >> 16) }
        for (name, data) in items {
            let offset = body.count
            let n = Data(name.utf8)
            put32(&body, 0x0403_4b50); put16(&body, 20); put16(&body, 0); put16(&body, Int(method)); put16(&body, 0)
            put16(&body, 0); put32(&body, 0); put32(&body, data.count); put32(&body, data.count)
            put16(&body, n.count); put16(&body, 0); body += n; body += data
            put32(&directory, 0x0201_4b50); put16(&directory, 20); put16(&directory, 20); put16(&directory, 0)
            put16(&directory, Int(method)); put16(&directory, 0); put16(&directory, 0); put32(&directory, 0)
            put32(&directory, data.count); put32(&directory, data.count); put16(&directory, n.count)
            put16(&directory, 0); put16(&directory, 0); put16(&directory, 0); put16(&directory, 0)
            put32(&directory, 0); put32(&directory, offset); directory += n
        }
        var end = Data()
        put32(&end, 0x0605_4b50); put16(&end, 0); put16(&end, 0); put16(&end, items.count); put16(&end, items.count)
        put32(&end, directory.count); put32(&end, body.count); put16(&end, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).zip")
        try (body + directory + end).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAFolderInstallsAndIsListed() throws {
        let root = tempRoot()
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
        let model = try MathModelImport.install(from: tinyFolder(), root: root)
        let listed = MathModelStore.installedModels(root: root)
        XCTAssertEqual(listed, [model])
        XCTAssertEqual(model.manifestSHA256, FileDigest.sha256(try Data(contentsOf: tinyFolder().appendingPathComponent("manifest.json"))))
        XCTAssertGreaterThan(model.totalBytes, 0)
        // Again: replaces, still one.
        _ = try MathModelImport.install(from: tinyFolder(), root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root).count, 1)
        // A damaged copy is not listed.
        try Data("x".utf8).write(to: model.folder.appendingPathComponent("tokenizer.json"))
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
    }

    func testAZipInstallsWithOrWithoutAFolderAroundIt() throws {
        for prefix in ["", "math-tiny/"] {
            let root = tempRoot()
            let model = try MathModelImport.install(from: zip(of: tinyFolder(), prefix: prefix,
                                                             extra: [("__MACOSX/._manifest.json", Data("junk".utf8)), (prefix + "notes.txt", Data("x".utf8))]),
                                                    root: root)
            XCTAssertEqual(MathModelStore.installedModels(root: root), [model], "prefix \(prefix)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.folder.appendingPathComponent("notes.txt").path),
                           "only the manifest's files are installed")
        }
    }

    func testBadModelsAreRefusedAndLeaveNothingBehind() throws {
        let root = tempRoot()
        // Compressed entries are not supported.
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: tinyFolder(), method: 8), root: root))
        // Not a zip, an empty folder, a missing file, a changed file.
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).zip")
        try Data("not a zip".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try MathModelImport.install(from: junk, root: root))
        XCTAssertThrowsError(try MathModelImport.install(from: FileManager.default.temporaryDirectory, root: root)) { error in
            XCTAssertEqual(error as? MathModelImport.Failure, .noManifest)
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: tinyFolder(), to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        let tokenizer = copy.appendingPathComponent("tokenizer.json")
        var data = try Data(contentsOf: tokenizer)
        data[data.startIndex] ^= 1
        try data.write(to: tokenizer)
        XCTAssertThrowsError(try MathModelImport.install(from: copy, root: root)) { error in
            XCTAssertEqual(error as? MathModelManifest.Failure, .mismatch("tokenizer.json"))
        }
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: copy), root: root))
        try FileManager.default.removeItem(at: tokenizer)
        XCTAssertThrowsError(try MathModelImport.install(from: copy, root: root)) { error in
            XCTAssertEqual(error as? MathModelImport.Failure, .missingEntry("tokenizer.json"))
        }
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: copy), root: root))
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(left.allSatisfy { !$0.hasPrefix(".staging") }, "staging is cleaned up: \(left)")
    }

    #if os(macOS)
    /// The zip the maintainer is told to make: `zip -0 -r` (what Finder's Compress would deflate, so stored).
    func testAZipMadeByTheZipToolInstalls() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString).zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-0", "-r", "-q", out.path, "."]
        p.currentDirectoryURL = try tinyFolder()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let root = tempRoot()
        let model = try MathModelImport.install(from: out, root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root), [model])
    }
    #endif
}
