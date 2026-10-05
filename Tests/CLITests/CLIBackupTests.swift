import Age
import Foundation
import InkVault
import XCTest

/// `keys paper`, `backup`, `backup verify`, `restore`.
final class CLIBackupTests: CLITestCase {
    /// The text drawn on the PDF's pages (our own uncompressed `(...) Tj` lines).
    private func pdfText(_ path: String) throws -> [String] {
        let s = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        return s.split(separator: "\n").filter { $0.hasPrefix("(") && $0.hasSuffix(") Tj") }
            .map { String($0.dropFirst().dropLast(4)).replacingOccurrences(of: "\\(", with: "(")
                .replacingOccurrences(of: "\\)", with: ")").replacingOccurrences(of: "\\\\", with: "\\") }
    }

    /// The printed key file: each line is drawn as number, text, checksum.
    private func lockedFile(_ text: [String], _ begin: Int, _ end: Int) -> String {
        stride(from: begin, through: end, by: 3).map { text[$0] }.joined(separator: "\n") + "\n"
    }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - keys paper

    func testPaperKitPlain() throws {
        let out = path("kit.pdf")
        let r = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--vault", Self.fixtureVault,
                         "--out", out, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["variant"] as? String, "plain")
        XCTAssertEqual(json["qrVersion"] as? Int, 6)
        XCTAssertEqual(json["qrErrorCorrection"] as? String, "Q")
        XCTAssertEqual(json["vaultId"] as? String, "5a3b1e00-1000-4000-8000-000000000001")
        XCTAssertEqual(try mode(out) & 0o777, 0o600)
        let key = try fixtureIdentity().string
        let text = try pdfText(out)
        for l in PaperKey.identityLines(key) { XCTAssertTrue(text.contains(l.groups.joined(separator: " "))) }
        XCTAssertTrue(text.contains("Vault:      sample"))

        let again = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--out", out])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("refusing to overwrite"), again.err)
    }

    func testPaperKitRefusesAKeyThatDoesNotOpenTheVault() throws {
        let other = path("other.key")
        try IdentityFile.render(X25519Identity(), created: Date()).write(toFile: other, atomically: true, encoding: .utf8)
        let r = try cli(["keys", "paper", "--identity", other, "--vault", Self.fixtureVault, "--out", path("k.pdf")])
        XCTAssertEqual(r.status, 4, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("k.pdf")))
        let none = try cli(["keys", "paper", "--out", path("k.pdf")])
        XCTAssertEqual(none.status, 4, none.err)
    }

    func testPaperKitFromTheVaultsStoredKeyFile() throws {
        let out = path("locked.pdf")
        let r = try cli(["keys", "paper", "--passphrase", "--vault", Self.fixtureVault, "--out", out],
                        env: ["INKVAULT_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.err)
        let raw = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        XCTAssertFalse(raw.contains("AGE-SECRET-KEY"), "a passphrase kit never holds the plain key")
        // The printed file is the vault's key file, and opens with the passphrase.
        let text = try pdfText(out)
        let begin = try XCTUnwrap(text.firstIndex(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.firstIndex(of: "-----END AGE ENCRYPTED FILE-----"))
        let armored = lockedFile(text, begin, end)
        let plain = try AgeFile.decrypt(Data(armored.utf8), with: [ScryptIdentity(passphrase: Self.passphrase)])
        XCTAssertEqual(try IdentityFile.parse(String(decoding: plain, as: UTF8.self)).recipient,
                       try fixtureIdentity().recipient)

        let wrong = try cli(["keys", "paper", "--passphrase", "--vault", Self.fixtureVault, "--out", path("w.pdf")],
                            env: ["INKVAULT_PASSPHRASE": "wrong"])
        XCTAssertEqual(wrong.status, 4, wrong.err)
    }

    func testPaperKitWithANewPassphrase() throws {
        let out = path("new.pdf")
        let r = try cli(["keys", "paper", "--passphrase", "--identity", Self.fixtureKey, "--work-factor", "15",
                         "--paper", "a4", "--out", out, "--passphrase-env", "KIT_PASS"],
                        env: ["KIT_PASS": "correct horse"])
        XCTAssertEqual(r.status, 0, r.err)
        let text = try pdfText(out)
        let begin = try XCTUnwrap(text.firstIndex(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.firstIndex(of: "-----END AGE ENCRYPTED FILE-----"))
        let plain = try AgeFile.decrypt(Data(lockedFile(text, begin, end).utf8),
                                        with: [ScryptIdentity(passphrase: "correct horse")])
        XCTAssertEqual(try IdentityFile.parse(String(decoding: plain, as: UTF8.self)).string, try fixtureIdentity().string)
        XCTAssertTrue(String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
            .contains("/MediaBox [0 0 595.28 841.89]"))
        let bad = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--paper", "a3", "--out", path("x.pdf")])
        XCTAssertEqual(bad.status, 2)
    }

    // MARK: - backup, verify, restore

    func testBackupVerifyRestoreRoundTrip() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        let first = try cli(["backup", vault, "--to", dir, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let report = try XCTUnwrap(first.json as? [String: Any])
        XCTAssertEqual((report["copied"] as? [String])?.count, 9)
        let second = try cli(["backup", "--vault", vault, "--to", dir, "--json"])
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertEqual((second.json as? [String: Any])?["unchanged"] as? Int, 9)

        let locked = try cli(["backup", "verify", dir])
        XCTAssertEqual(locked.status, 0, locked.out + locked.err)
        XCTAssertTrue(locked.out.contains("not decrypted"))
        let full = try cli(["backup", "verify", dir, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(full.status, 0, full.out + full.err)
        XCTAssertEqual((full.json as? [String: Any])?["decrypted"] as? Bool, true)
        // A scripted passphrase unlocks the key file the backup holds.
        let viaPass = try cli(["backup", "verify", dir], env: ["INKVAULT_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(viaPass.status, 0, viaPass.out + viaPass.err)
        XCTAssertTrue(viaPass.out.contains("decrypted and verified"), viaPass.out)

        let target = path("restored.inkvault")
        let restore = try cli(["restore", dir, "--to", target, "--identity", Self.fixtureKey])
        XCTAssertEqual(restore.status, 0, restore.out + restore.err)
        let verify = try cli(["vault", "verify", "--vault", target, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out)
        let notes = try cli(["notes", "list", "--deleted", "--vault", target, "--identity", Self.fixtureKey])
        XCTAssertTrue(notes.out.contains("Fixture lecture"), notes.out)

        let notVault = try cli(["restore", dir, "--to", path("plain")])
        XCTAssertEqual(notVault.status, 2)
        let again = try cli(["restore", dir, "--to", target])
        XCTAssertEqual(again.status, 1, again.err)
    }

    func testBackupVerifyFindsDamage() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        XCTAssertEqual(try cli(["backup", vault, "--to", dir]).status, 0)
        let note = URL(fileURLWithPath: dir).appendingPathComponent("notes/\(Self.lecture)")
        let files = try FileManager.default.contentsOfDirectory(atPath: note.path).sorted()
        let victim = note.appendingPathComponent(files[0])
        var d = try Data(contentsOf: victim)
        d[d.count - 3] ^= 0x01
        try d.write(to: victim)
        try FileManager.default.removeItem(at: note.appendingPathComponent(files[1]))

        let r = try cli(["backup", "verify", dir, "--json"])
        XCTAssertEqual(r.status, 3, r.out)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["healthy"] as? Bool, false)
        let statuses = (json["files"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            $0[$1["path"] as? String ?? ""] = $1["status"] as? String
        }
        XCTAssertEqual(statuses["notes/\(Self.lecture)/\(files[0])"], "modified")
        XCTAssertEqual(statuses["notes/\(Self.lecture)/\(files[1])"], "missing")
        let human = try cli(["backup", "verify", dir, "--identity", Self.fixtureKey])
        XCTAssertEqual(human.status, 3)
        XCTAssertTrue(human.out.contains("modified  notes/\(Self.lecture)/\(files[0])"), human.out)
        let wrongKey = path("w.key")
        try IdentityFile.render(X25519Identity(), created: Date()).write(toFile: wrongKey, atomically: true, encoding: .utf8)
        XCTAssertEqual(try cli(["backup", "verify", dir, "--identity", wrongKey]).status, 4)

        // The restore refuses the damaged file and says so.
        let restore = try cli(["restore", dir, "--to", path("r.inkvault")])
        XCTAssertEqual(restore.status, 1)
        XCTAssertTrue(restore.err.contains(files[0]), restore.err)
    }

    func testBackupUsageAndPrune() throws {
        let vault = try copyFixtureVault()
        XCTAssertEqual(try cli(["backup", vault]).status, 2)
        XCTAssertEqual(try cli(["backup", vault, "--to", path("a"), "--archive", path("b.tar")]).status, 2)
        XCTAssertEqual(try cli(["backup", vault, "--archive", path("b.tar"), "--prune"]).status, 2)
        let noKey = try cli(["backup", vault, "--to", path("a"), "--prune"])
        XCTAssertEqual(noKey.status, 4, noKey.err)
        let pruned = try cli(["backup", vault, "--to", path("a"), "--prune", "--identity", Self.fixtureKey])
        XCTAssertEqual(pruned.status, 0, pruned.err)
        // Someone else's folder is never written into.
        let busy = path("busy")
        try FileManager.default.createDirectory(atPath: busy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: busy).appendingPathComponent("thesis.tex"))
        let refused = try cli(["backup", vault, "--to", busy])
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("not an inkvault backup"), refused.err)
    }

    func testArchive() throws {
        let vault = try copyFixtureVault()
        let tar = path("notes.tar")
        let r = try cli(["backup", vault, "--archive", tar, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual((r.json as? [String: Any])?["files"] as? Int, 9)
        XCTAssertEqual(try cli(["backup", vault, "--archive", tar]).status, 1, "refuses to overwrite")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: tar))
        XCTAssertNil(String(decoding: bytes, as: UTF8.self).range(of: "Fixture lecture"), "no plaintext in the archive")
    }
}
