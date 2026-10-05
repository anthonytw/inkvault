import Age
import Foundation
import XCTest

/// Post-quantum keys through the CLI: key generation, and the migration of
/// an X25519 vault to an MLKEM768-X25519 key (format.md §3.3.2).
final class CLIPostQuantumTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS (needs macOS 26)") }
    }

    func generate(_ name: String, _ flags: [String] = []) throws -> String {
        let r = try cli(["keys", "generate", "--out", path(name), "-q"] + flags)
        XCTAssertEqual(r.status, 0, r.err)
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testKeysGenerateKinds() throws {
        XCTAssertTrue(try generate("default.key").hasPrefix("age1pq1"))
        XCTAssertTrue(try generate("pq.key", ["--pq"]).hasPrefix("age1pq1"))
        let classic = try generate("x.key", ["--x25519"])
        XCTAssertTrue(classic.hasPrefix("age1") && !classic.hasPrefix("age1pq1"), classic)
        XCTAssertEqual(try cli(["keys", "generate", "--pq", "--x25519"]).status, 2)
        let text = try String(contentsOfFile: path("pq.key"), encoding: .utf8)
        XCTAssertTrue(text.contains("\nAGE-SECRET-KEY-PQ-1"), text)
        let shown = try cli(["keys", "show", path("pq.key")])
        XCTAssertEqual(shown.out.trimmingCharacters(in: .whitespacesAndNewlines), try generateShow("pq.key"))
    }

    private func generateShow(_ name: String) throws -> String {
        let text = try String(contentsOfFile: path(name), encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("# public key: ") })
        return String(line.dropFirst("# public key: ".count))
    }

    func stanzaTypes(_ vault: String) throws -> Set<[String]> {
        var out = Set<[String]>()
        let notes = URL(fileURLWithPath: vault).appendingPathComponent("notes")
        for note in try FileManager.default.contentsOfDirectory(atPath: notes.path) {
            let dir = notes.appendingPathComponent(note)
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                out.insert(try AgeFile.parseHeader(Data(contentsOf: dir.appendingPathComponent(f))).header.stanzas.map(\.type))
            }
        }
        return out
    }

    /// One-step migration: `recipients replace` swaps the X25519 key for a
    /// post-quantum one with a single rewrap; no file is ever mixed.
    func testReplaceMigratesVaultToPostQuantum() throws {
        let (vault, _, oldKey) = try makeVault()
        let old = try generateShow(URL(fileURLWithPath: oldKey).lastPathComponent)
        XCTAssertEqual(try stanzaTypes(vault.url.path), [["X25519"]])
        _ = try generate("pq.key")
        let before = try cli(["vault", "info", "--vault", vault.url.path])
        XCTAssertTrue(before.out.contains("Post-quantum:   NO (1 X25519"), before.out)

        // The new key is given as its identity file: only the public key line is read.
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.url.path,
                         "--identity", oldKey])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(vault.url.path), [["mlkem768x25519"]])
        let after = try cli(["vault", "info", "--vault", vault.url.path, "--json"])
        let recips = try XCTUnwrap((after.json as? [String: Any])?["recipients"] as? [[String: Any]])
        XCTAssertEqual(recips.map { $0["type"] as? String }, ["mlkem768x25519"])
        XCTAssertEqual(recips.first?["label"] as? String, "laptop")
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.url.path, "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault.url.path, "--identity", path("pq.key")]).status, 0)
        // The old key is locked out (exit 4: no key decrypts).
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.url.path, "--identity", oldKey]).status, 4)
        // Replacing again: the old key is gone.
        let again = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.url.path,
                             "--identity", path("pq.key")])
        XCTAssertNotEqual(again.status, 0)
    }

    /// Two-step migration (several devices): add the PQ key (files are
    /// mixed meanwhile and `info` says so), then remove the X25519 key.
    func testAddThenRemoveMigration() throws {
        let (vault, _, oldKey) = try makeVault()
        let old = try generateShow(URL(fileURLWithPath: oldKey).lastPathComponent)
        let pq = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "add", pq, "--vault", vault.url.path, "--identity", oldKey]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.url.path), [["X25519", "mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.url.path]).out.contains("Post-quantum:   NO"))
        for key in [oldKey, path("pq.key")] {
            XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.url.path, "--identity", key]).status, 0)
        }
        XCTAssertEqual(try cli(["vault", "recipients", "remove", old, "--vault", vault.url.path,
                                "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.url.path), [["mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.url.path]).out.contains("Post-quantum:   yes"))
    }

    /// The stock-CLI recovery path (CLAUDE.md) works on a post-quantum vault
    /// with age 1.3 or later.
    func testStockAgeRecoversPostQuantumVault() throws {
        let (vault, _, oldKey) = try makeVault()
        let old = try generateShow(URL(fileURLWithPath: oldKey).lastPathComponent)
        _ = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.url.path,
                                "--identity", oldKey]).status, 0)
        guard let age = Self.agePQ() else {
            if ProcessInfo.processInfo.environment["INKVAULT_REQUIRE_AGE_PQ"] != nil {
                XCTFail("INKVAULT_REQUIRE_AGE_PQ set but no age >= 1.3 on PATH")
            }
            throw XCTSkip("no age >= 1.3 on PATH")
        }
        let notes = vault.url.appendingPathComponent("notes")
        let note = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.path).first)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path).first)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "\"$0\" -d -i \"$1\" \"$2\" | tail -c +38 | gunzip", age, path("pq.key"),
                        notes.appendingPathComponent(note).appendingPathComponent(file).path]
        let pipe = Pipe()
        sh.standardOutput = pipe
        try sh.run()
        let json = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["noteId"] as? String, note)
    }

    /// The first `age` on PATH (or in the usual places) that is 1.3 or later.
    static func agePQ() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let age = "\(dir)/age"
            guard FileManager.default.isExecutableFile(atPath: age) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: age)
            p.arguments = ["--version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { continue }
            let v = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let parts = v.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
                .split(separator: ".").prefix(2).compactMap { Int($0) }
            if parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) { return age }
        }
        return nil
    }
}
