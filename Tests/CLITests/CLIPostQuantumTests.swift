import Age
import Foundation
import InkVault
import XCTest

/// Post-quantum keys through the CLI: key generation, the refusal of
/// classic keys, and the migration of a legacy X25519 vault (the fixture) to
/// an MLKEM768-X25519 key (format.md §3.3.2).
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

    func testKeysArePostQuantumOnly() throws {
        XCTAssertTrue(try generate("pq.key").hasPrefix("age1pq1"))
        XCTAssertEqual(try cli(["keys", "generate", "--x25519"]).status, 2, "no classic option")
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
        let vault = URL(fileURLWithPath: try copyFixtureVault()), oldKey = Self.fixtureKey
        let old = try fixtureIdentity().recipient.string
        XCTAssertEqual(try stanzaTypes(vault.path), [["X25519"]])
        _ = try generate("pq.key")
        let before = try cli(["vault", "info", "--vault", vault.path])
        XCTAssertTrue(before.out.contains("Post-quantum:   NO (1 X25519"), before.out)

        // The new key is given as its identity file: only the public key line is read.
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                         "--identity", oldKey])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
        let after = try cli(["vault", "info", "--vault", vault.path, "--json"])
        let recips = try XCTUnwrap((after.json as? [String: Any])?["recipients"] as? [[String: Any]])
        XCTAssertEqual(recips.map { $0["type"] as? String }, ["mlkem768x25519"])
        XCTAssertEqual(recips.first?["label"] as? String, "InkVault test fixture (throwaway, test-only key)")
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.path, "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault.path, "--identity", path("pq.key")]).status, 0)
        // The old key is locked out (exit 4: no key decrypts).
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.path, "--identity", oldKey]).status, 4)
        // Replacing again: the old key is gone.
        let again = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                             "--identity", path("pq.key")])
        XCTAssertNotEqual(again.status, 0)
    }

    /// Two-step migration (several devices): add the PQ key (files are
    /// mixed meanwhile and `info` says so), then remove the X25519 key.
    func testAddThenRemoveMigration() throws {
        let vault = URL(fileURLWithPath: try copyFixtureVault()), oldKey = Self.fixtureKey
        let old = try fixtureIdentity().recipient.string
        let pq = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "add", pq, "--vault", vault.path, "--identity", oldKey]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.path), [["X25519", "mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.path]).out.contains("Post-quantum:   NO"))
        for key in [oldKey, path("pq.key")] {
            XCTAssertEqual(try cli(["vault", "verify", "--vault", vault.path, "--identity", key]).status, 0)
        }
        XCTAssertEqual(try cli(["vault", "recipients", "remove", old, "--vault", vault.path,
                                "--identity", path("pq.key")]).status, 0)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault.path]).out.contains("Post-quantum:   yes"))
    }

    /// The stock-CLI recovery path (CLAUDE.md) works on a post-quantum vault
    /// with age 1.3 or later.
    func testStockAgeRecoversPostQuantumVault() throws {
        let vault = URL(fileURLWithPath: try copyFixtureVault()), oldKey = Self.fixtureKey
        let old = try fixtureIdentity().recipient.string
        _ = try generate("pq.key")
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", vault.path,
                                "--identity", oldKey]).status, 0)
        guard let age = Self.agePQ() else {
            if ProcessInfo.processInfo.environment["INKVAULT_REQUIRE_AGE_PQ"] != nil {
                XCTFail("INKVAULT_REQUIRE_AGE_PQ set but no age >= 1.3 on PATH")
            }
            throw XCTSkip("no age >= 1.3 on PATH")
        }
        let notes = vault.appendingPathComponent("notes")
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

    /// Vaults take no classic X25519 recipient: init, add and replace refuse
    /// it with "create a new key" (exit 2) and leave nothing behind.
    func testClassicRecipientsRefused() throws {
        let classic = X25519Identity().recipient.string
        let initR = try cli(["vault", "init", path("v.inkvault"), "--recipient", classic])
        XCTAssertEqual(initR.status, 2)
        XCTAssertTrue(initR.err.contains("create a new key"), initR.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("v.inkvault")))
        let (made, _, key) = try makeVault()
        let vault = made.url
        let add = try cli(["vault", "recipients", "add", classic, "--vault", vault.path, "--identity", key])
        XCTAssertEqual(add.status, 2, add.err)
        let mine = try generateShow(URL(fileURLWithPath: key).lastPathComponent)
        let rep = try cli(["vault", "recipients", "replace", mine, classic, "--vault", vault.path, "--identity", key])
        XCTAssertEqual(rep.status, 2, rep.err)
        XCTAssertEqual(try stanzaTypes(vault.path), [["mlkem768x25519"]])
    }

    /// A classic key is refused before anything else happens: no
    /// passphrase is asked for (none is available here, which used to end in
    /// exit 4 "no passphrase" instead of the real reason).
    func testClassicRecipientRefusedBeforeUnlocking() throws {
        let classicID = X25519Identity()
        let classic = classicID.recipient.string
        try IdentityFile.render(classicID, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                  encoding: .utf8)
        let vault = try copyFixtureVault()
        let old = try fixtureIdentity().recipient.string
        for args in [["vault", "recipients", "add", classic, "--vault", vault],
                     ["vault", "recipients", "replace", old, classic, "--vault", vault],
                     ["vault", "init", path("n.inkvault"), "--recipient", classic, "--store-key", path("classic.key")]] {
            let r = try cli(args)
            XCTAssertEqual(r.status, 2, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("create a new key"), r.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("n.inkvault")))
        XCTAssertEqual(try stanzaTypes(vault), [["X25519"]])
    }

    /// A classic identity offered to a post-quantum vault fails with the
    /// reason (exit 4), not only "no key matches".
    func testClassicIdentityExplained() throws {
        let (made, _, _) = try makeVault()
        let classic = X25519Identity()
        try IdentityFile.render(classic, created: Date()).write(toFile: path("classic.key"), atomically: true,
                                                                encoding: .utf8)
        let r = try cli(["notes", "list", "--vault", made.url.path, "--identity", path("classic.key")])
        XCTAssertEqual(r.status, 4, r.err)
        XCTAssertTrue(r.err.contains("classic X25519 key") && r.err.contains("create a new key"), r.err)
    }

    /// Migrating a vault unlocked by passphrase (the fixture's stored
    /// X25519 key): without `--store-key` the old key file must not be
    /// offered any more (it used to be, and the vault then failed with "none
    /// of the given keys can decrypt"); with it, the same passphrase opens the
    /// new key.
    func testReplaceKeepsPassphraseUnlock() throws {
        let old = try fixtureIdentity().recipient.string
        let pass = ["INKVAULT_PASSPHRASE": Self.passphrase]
        _ = try generate("pq.key")

        let plain = try copyFixtureVault(as: "plain.inkvault")
        XCTAssertEqual(try cli(["notes", "list", "--vault", plain], env: pass).status, 0)
        XCTAssertEqual(try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", plain],
                               env: pass).status, 0)
        let after = try cli(["notes", "list", "--vault", plain], env: pass)
        XCTAssertEqual(after.status, 4, after.err)
        XCTAssertTrue(after.err.contains("stores no passphrase-wrapped key"), after.err)

        let stored = try copyFixtureVault(as: "stored.inkvault")
        let r = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", stored,
                         "--store-key", path("pq.key"), "--work-factor", "15"], env: pass)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try stanzaTypes(stored), [["mlkem768x25519"]])
        let list = try cli(["notes", "list", "--vault", stored], env: pass)
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertTrue(list.out.contains("Fixture lecture"), list.out)
        let info = try cli(["vault", "info", "--vault", stored, "--json"])
        XCTAssertEqual(((info.json as? [String: Any])?["keyFiles"] as? [String])?.count, 1, info.out)

        // --store-key must be the new recipient's key, checked before any change.
        let other = try copyFixtureVault(as: "other.inkvault")
        let wrong = try cli(["vault", "recipients", "replace", old, path("pq.key"), "--vault", other,
                             "--store-key", Self.fixtureKey], env: pass)
        XCTAssertEqual(wrong.status, 2, wrong.err)
        XCTAssertEqual(try stanzaTypes(other), [["X25519"]])
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
