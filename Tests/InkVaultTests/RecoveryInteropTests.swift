import Age
import Foundation
import XCTest
@testable import InkVault

/// Guards the no-app recovery promise (CLAUDE.md, format.md §4):
/// `age -d -i key FILE.age | tail -c +38 | gunzip` yields the revision JSON.
/// Skipped when `age` is not on PATH.
final class RecoveryInteropTests: VaultTestCase {
    static func which(_ name: String) -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func shell(_ script: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe(), err = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: stderr, as: UTF8.self))
        return stdout
    }

    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func testStockAgeRecoveryPipeline() throws {
        guard let age = Self.which("age") else { throw XCTSkip("age not on PATH") }
        // A legacy X25519 vault: the library refuses its notes until it is
        // migrated, but the stock-CLI recovery path keeps working on it.
        let id = X25519Identity()
        let legacy = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        XCTAssertThrowsError(try legacy.summaries()) {
            XCTAssertEqual($0 as? VaultError, .legacyVault(recipients: [id.recipient.string]))
        }
        let vault = legacy.allowingLegacyContent()   // test seam: write the notes to recover
        var clock = HybridClock()
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")

        // Identity as plain text, the way a user would export it.
        let keyFile = tmp.appendingPathComponent("key.txt")
        try IdentityFile.render(id, created: Date()).write(to: keyFile, atomically: true, encoding: .utf8)

        for rev in [log[0], log[2], snap] {
            let file = fileURL(vault, testNote, rev.name)
            let json = try shell("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(json, try InkJSON.encoder().encode(rev), "byte-identical JSON for \(rev.name)")
            XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json),
                           try vault.readRevision(noteId: testNote, name: rev.name))
        }

        // The armored vault secret also opens with stock age.
        let secretFile = tmp.appendingPathComponent("secret.age")
        try Data(vault.manifest.vaultSecret.utf8).write(to: secretFile)
        let secret = try shell("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(secretFile.path))")
        XCTAssertEqual(secret, vault.secret?.bytes)
    }
}
