import Age
import Foundation
import XCTest
@testable import InkVault

/// Vaults with MLKEM768-X25519 recipients (format.md §3.3.2): creation,
/// mixed sets, the replace migration (interrupted and resumed), key files.
final class PostQuantumVaultTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS (needs macOS 26)") }
    }

    func pq() throws -> NativeIdentity { try NativeIdentity.generate(.postQuantum) }

    func types(_ vault: Vault, _ revs: [Revision]) throws -> Set<[String]> {
        Set(try revs.map {
            try AgeFile.parseHeader(Data(contentsOf: fileURL(vault, $0.noteId, $0.name))).header.stanzas.map(\.type)
        })
    }

    func assertReadable(_ revs: [Revision], at url: URL, by id: NativeIdentity, line: UInt = #line) throws {
        let v = try Vault.open(at: url, identities: [id])
        for r in revs { XCTAssertEqual(try v.readRevision(noteId: r.noteId, name: r.name), r, line: line) }
        let report = v.verify()
        XCTAssertTrue(report.isHealthy, "\(report)", line: line)
    }

    func testPostQuantumOnlyVault() throws {
        let id = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        let revs = try populate(vault)
        XCTAssertEqual(try types(vault, revs), [["mlkem768x25519"]])
        let secretStanzas = try AgeFile.parseHeader(Armor.decode(Data(vault.manifest.vaultSecret.utf8))).header.stanzas
        XCTAssertEqual(secretStanzas.map(\.type), ["mlkem768x25519"])
        try assertReadable(revs, at: vault.url, by: id)
        // A classic key does not open it.
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [X25519Identity()]))
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [try pq()]))
    }

    /// Vaults are post-quantum only: no classic recipient enters through
    /// the public API (create, add, replace), and nothing is written.
    func testClassicRecipientsRefused() throws {
        let classic = NativeRecipient.x25519(X25519Identity().recipient), id = try pq()
        XCTAssertThrowsError(try Vault.create(at: vaultURL("C"), recipients: [classic])) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertThrowsError(try Vault.create(at: vaultURL("M"), recipients: [id.recipient, classic]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL("C").path))
        var vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        XCTAssertThrowsError(try vault.addRecipient(classic, label: "old")) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertThrowsError(try vault.replaceRecipient(id.recipient, with: classic)) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.string))
        }
        XCTAssertEqual(vault.recipients.map(\.key), [id.recipient.string])
        XCTAssertFalse(vault.pendingRewrap)
    }

    /// The one-step migration: an X25519 vault becomes PQ-only with a single
    /// rewrap; an interruption is finished by repeating the call, and no
    /// file ever carries both stanza types.
    func testReplaceMigrationInterruptedAndResumed() throws {
        let old = X25519Identity(), new = try pq()
        var vault = try Vault.create(at: vaultURL(), recipients: [old.recipient], labels: ["iPad"], identities: [old])
        let revs = try populate(vault)
        let oldSecret = try XCTUnwrap(vault.secret)
        XCTAssertThrowsError(try vault.replaceRecipient(.x25519(old.recipient), with: new.recipient, label: nil,
                                                        added: Date(), stopAfter: 2)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }
        XCTAssertTrue(vault.pendingRewrap)
        XCTAssertEqual(try types(vault, revs), [["X25519"], ["mlkem768x25519"]])
        // Mid-way only the new key opens vault.json, and the files not yet
        // rewrapped open only with the old one: finishing needs both.
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [old]))
        var newOnly = try Vault.open(at: vault.url, identities: [new])
        XCTAssertEqual(newOnly.verify().counts[.undecryptable], revs.count - 2)
        let stuck = try newOnly.replaceRecipient(.x25519(old.recipient), with: new.recipient)
        XCTAssertEqual(stuck.failures.count, revs.count - 2)
        XCTAssertTrue(newOnly.pendingRewrap, "the journal stays until every file is done")
        var again = try Vault.open(at: vault.url, identities: [.x25519(old), new])
        XCTAssertEqual(again.verify().counts[.staleRecipients], revs.count - 2)
        let report = try again.replaceRecipient(.x25519(old.recipient), with: new.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(again.pendingRewrap)
        XCTAssertEqual(try types(again, revs), [["mlkem768x25519"]])
        XCTAssertEqual(again.recipients.map(\.label), ["iPad"])
        XCTAssertNotEqual(again.secret, oldSecret, "the secret rotates: the old key could read it")
        try assertReadable(revs, at: vault.url, by: new)
        // Repeating a finished replace is an error (old key no longer listed).
        XCTAssertThrowsError(try again.replaceRecipient(.x25519(old.recipient), with: new.recipient)) {
            XCTAssertEqual($0 as? VaultError, .unknownRecipient(old.recipient.string))
        }
    }

    func testReplaceRejectsDuplicateAndUnknown() throws {
        let a = X25519Identity(), b = try pq()
        var vault = try Vault.createUnchecked(at: vaultURL(), recipients: [.x25519(a.recipient), b.recipient],
                                              labels: [], identities: [a], vaultId: UUID(), created: Date())
        XCTAssertThrowsError(try vault.replaceRecipient(.x25519(a.recipient), with: b.recipient)) {
            XCTAssertEqual($0 as? VaultError, .duplicateRecipient(b.recipient.string))
        }
        XCTAssertThrowsError(try vault.replaceRecipient(.x25519(X25519Identity().recipient), with: try pq().recipient))
    }

    /// Several devices: the PQ key is added (files carry both stanza
    /// types, readable by either key), then the X25519 key is removed.
    func testMixedVaultThenRemoveClassic() throws {
        let old = X25519Identity(), new = try pq()
        var vault = try Vault.create(at: vaultURL(), recipients: [old.recipient], identities: [old])
        let revs = try populate(vault)
        try vault.addRecipient(new.recipient, label: "pq")
        XCTAssertEqual(try types(vault, revs), [["X25519", "mlkem768x25519"]])
        try assertReadable(revs, at: vault.url, by: .x25519(old))
        try assertReadable(revs, at: vault.url, by: new)
        // New writes in a mixed vault carry both too.
        var more = sampleLog()[0]
        more.noteId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        try vault.write(more)
        XCTAssertEqual(try types(vault, [more]), [["X25519", "mlkem768x25519"]])
        // Adding the PQ key did not make the existing files stale.
        XCTAssertTrue(vault.verify().isHealthy)

        try vault.removeRecipient(.x25519(old.recipient))
        XCTAssertEqual(try types(vault, revs + [more]), [["mlkem768x25519"]])
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [old]))
        try assertReadable(revs + [more], at: vault.url, by: new)
    }

    /// A file encrypted to the right number of recipients but the wrong
    /// types is not "complete" (format.md §3.3.1) and gets rewrapped.
    func testCompletenessCountsStanzaTypes() throws {
        let a = X25519Identity(), b = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [b.recipient], identities: [a, b])
        let revs = try populate(vault)
        // Plant a file encrypted to one X25519 recipient only.
        let target = revs[0]
        let url = fileURL(vault, target.noteId, target.name)
        let plain = try AgeFile.decrypt(Data(contentsOf: url), with: [b])
        try AgeFile.encrypt(plain, to: [a.recipient]).write(to: url)
        let report = vault.verify()
        XCTAssertEqual(report.counts[.staleRecipients], 1)
        XCTAssertEqual(try Vault.stanzaCounts(Data(contentsOf: url)), ["X25519": 1])
        XCTAssertEqual(Vault.expectedStanzas(try vault.ageRecipients()), ["mlkem768x25519": 1])
        let rewrap = try vault.rewrapNotes(stopAfter: nil)
        XCTAssertEqual(rewrap.rewrapped, ["\(target.noteId.uuidString.lowercased())/\(target.name.filename)"])
        XCTAssertEqual(try types(vault, revs), [["mlkem768x25519"]])
    }

    /// Passphrase-wrapped PQ key files: a hashed name (the recipient is too
    /// long for one), found through the manifest, round trip unchanged.
    func testIdentityFileForPostQuantumKey() throws {
        let id = try pq()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        let url = try vault.writeIdentityFile(id, passphrase: "pw", workFactor: 15)
        let name = url.lastPathComponent
        XCTAssertTrue(name.hasPrefix("age1pq-") && name.hasSuffix(".key.age"), name)
        XCTAssertEqual(name.count, "age1pq-".count + 64 + ".key.age".count)
        XCTAssertEqual(name, IdentityFile.fileName(for: id.recipient))
        XCTAssertTrue(IdentityFile.isKeyFileName(name))
        XCTAssertNil(IdentityFile.recipient(fromFileName: name))
        XCTAssertEqual(try vault.identityFiles(), [id.recipient])
        XCTAssertEqual(try vault.readIdentityFile(recipient: id.recipient, passphrase: "pw"), id)
        XCTAssertThrowsError(try vault.readIdentityFile(recipient: id.recipient, passphrase: "nope")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        // The plaintext is age-keygen -pq style, and verify accepts the name.
        let text = IdentityFile.render(id, created: Date())
        XCTAssertTrue(text.contains("\n# public key: age1pq1") && text.contains("\nAGE-SECRET-KEY-PQ-1"))
        XCTAssertEqual(try IdentityFile.parse(text), id)
        XCTAssertEqual(vault.verify().counts[.unknownFile] ?? 0, 0)
        XCTAssertFalse(IdentityFile.isKeyFileName("age1pq-xyz.key.age"))
    }
}
