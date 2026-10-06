import Foundation
import XCTest

/// CLI tests drive the built `sempere` binary as a subprocess, which works
/// identically on Linux and macOS and avoids linking the executable's `main`
/// into the test bundle.
final class CLISmokeTests: XCTestCase {
    static var binary: URL {
        // .build/<config>/CLITests.xctest or .build/<config>/sempere-corePackageTests.xctest
        var url = Bundle(for: CLISmokeTests.self).bundleURL
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("sempere").path) {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("sempere")
    }

    static func run(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testVersion() throws {
        let r = try Self.run(["--version"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(r.out.isEmpty)
    }
}
