import Age
import Foundation
import XCTest
@testable import InkVault

final class RecipientTests: VaultTestCase {
    /// Two notes, six files in all.
    func populate(_ vault: Vault) throws -> [Revision] {
        let log = sampleLog()
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        var extra = log[0]
        extra.noteId = other
        for r in log + [extra] { try vault.write(r) }
        return log + [extra]
    }

    func assertReadable(_ revs: [Revision], at url: URL, by id: X25519Identity, file: StaticString = #filePath,
                        line: UInt = #line) throws {
        let v = try Vault.open(at: url, identities: [id])
        for r in revs {
            XCTAssertEqual(try v.readRevision(noteId: r.noteId, name: r.name), r, file: file, line: line)
        }
        let report = v.verify()
        XCTAssertTrue(report.isHealthy, "\(report)", file: file, line: line)
        XCTAssertFalse(report.rewrapPending, file: file, line: line)
    }

    func stanzaCounts(_ vault: Vault, _ revs: [Revision]) throws -> [Int] {
        try revs.map { try AgeFile.parseHeader(Data(contentsOf: fileURL(vault, $0.noteId, $0.name))).header.stanzas.count }
    }

    func testAddRecipientLetsSecondIdentityRead() throws {
        let a = X25519Identity(), b = X25519Identity()
        var vault = try makeVault(a)
        let revs = try populate(vault)
        let secret = vault.secret
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [b]))

        let report = try vault.addRecipient(b.recipient, label: "B")
        XCTAssertEqual(report.rewrapped.count, revs.count)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(vault.secret, secret, "adding does not rotate the secret")
        XCTAssertEqual(vault.recipients.map(\.key), [a.recipient.string, b.recipient.string])
        XCTAssertEqual(try stanzaCounts(vault, revs), Array(repeating: 2, count: revs.count))
        try assertReadable(revs, at: vault.url, by: a)
        try assertReadable(revs, at: vault.url, by: b)

        // Plaintext unchanged by the add: same framed body (tag + gzip).
        let file = fileURL(vault, revs[0].noteId, revs[0].name)
        let body = try AgeFile.decrypt(Data(contentsOf: file), with: [b])
        XCTAssertEqual(try BodyFraming.unframe(body, noteId: testNote.uuidString.lowercased(),
                                               filename: revs[0].name.filename, secret: XCTUnwrap(secret)).verified, true)

        XCTAssertThrowsError(try vault.addRecipient(b.recipient, label: "again")) {
            XCTAssertEqual($0 as? VaultError, .duplicateRecipient(b.recipient.string))
        }
    }

    func testRemoveRecipientLocksItOutAndRotatesSecret() throws {
        let a = X25519Identity(), b = X25519Identity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["A", "B"],
                                     identities: [a])
        let revs = try populate(vault)
        let oldSecret = try XCTUnwrap(vault.secret)

        let report = try vault.removeRecipient(b.recipient)
        XCTAssertEqual(report.rewrapped.count, revs.count)
        XCTAssertNotEqual(vault.secret, oldSecret, "vault secret rotated on remove")
        XCTAssertEqual(vault.recipients.map(\.key), [a.recipient.string])
        XCTAssertFalse(vault.pendingRewrap)

        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [b])) {
            guard case .vaultSecretUndecryptable = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        for r in revs {
            XCTAssertThrowsError(try AgeFile.decrypt(Data(contentsOf: fileURL(vault, r.noteId, r.name)), with: [b]))
        }
        try assertReadable(revs, at: vault.url, by: a)
        // Files are tagged with the new secret, gzip bytes unchanged.
        let v = try Vault.open(at: vault.url, identities: [a])
        XCTAssertNotEqual(v.secret, oldSecret)

        XCTAssertThrowsError(try vault.removeRecipient(b.recipient)) {
            XCTAssertEqual($0 as? VaultError, .unknownRecipient(b.recipient.string))
        }
        XCTAssertThrowsError(try vault.removeRecipient(a.recipient)) {
            XCTAssertEqual($0 as? VaultError, .lastRecipient)
        }
    }

    func testInterruptedAddIsFinishedBySecondRun() throws {
        let a = X25519Identity(), b = X25519Identity()
        var vault = try makeVault(a)
        let revs = try populate(vault)
        XCTAssertThrowsError(try vault.addRecipient(b.recipient, label: "B", added: Date(), stopAfter: 3)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }

        // Fresh process: the journal says a change is unfinished.
        var again = try Vault.open(at: vault.url, identities: [a])
        XCTAssertTrue(again.pendingRewrap)
        let mid = again.verify()
        XCTAssertEqual(mid.counts[.ok], 3)
        XCTAssertEqual(mid.counts[.staleRecipients], 3)
        XCTAssertTrue(mid.rewrapPending)

        let report = try again.addRecipient(b.recipient, label: "B")
        XCTAssertEqual(report.alreadyCurrent.count, 3)
        XCTAssertEqual(report.rewrapped.count, 3)
        XCTAssertEqual(Set(report.alreadyCurrent + report.rewrapped).count, revs.count)
        XCTAssertFalse(again.pendingRewrap)
        XCTAssertEqual(try stanzaCounts(again, revs), Array(repeating: 2, count: revs.count))
        try assertReadable(revs, at: vault.url, by: b)
    }

    func testInterruptedRemoveIsFinishedByResume() throws {
        let a = X25519Identity(), b = X25519Identity()
        var vault = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], identities: [a])
        let revs = try populate(vault)
        let oldSecret = try XCTUnwrap(vault.secret)
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient, stopAfter: 2)) {
            XCTAssertEqual($0 as? VaultError, .interrupted)
        }

        var again = try Vault.open(at: vault.url, identities: [a])
        XCTAssertTrue(again.pendingRewrap)
        XCTAssertNotEqual(again.secret, oldSecret)
        XCTAssertEqual(again.previousSecret, oldSecret, "journal holds the outgoing secret")
        // Files not yet rewrapped still read (verified under the previous secret).
        for r in revs { XCTAssertEqual(try again.readRevision(noteId: r.noteId, name: r.name), r) }

        let report = try again.resumeRewrap()
        XCTAssertEqual(report.alreadyCurrent.count, 2)
        XCTAssertEqual(report.rewrapped.count, revs.count - 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(again.pendingRewrap)
        XCTAssertNil(again.previousSecret)
        try assertReadable(revs, at: vault.url, by: a)
        XCTAssertThrowsError(try Vault.open(at: vault.url, identities: [b]))

        // Without the journal, an old-secret file is a tag mismatch again.
        XCTAssertEqual(try again.resumeRewrap(), Vault.RewrapReport())
    }

    /// A rewrap never blesses a file it cannot verify (e.g. a planted one).
    func testRewrapLeavesUnverifiableFilesAlone() throws {
        let a = X25519Identity(), b = X25519Identity()
        var vault = try makeVault(a)
        let revs = try populate(vault)
        let planted = RevisionName(hlc: HLC(millis: baseMillis + 999, counter: 0)!, device: devC, seq: 1, kind: .delta)
        let body = BodyFraming.frame(gzip: try Gzip.compress(Data("{}".utf8)), noteId: testNote.uuidString.lowercased(),
                                     filename: planted.filename, secret: .random())
        let plantedURL = fileURL(vault, testNote, planted)
        let plantedBytes = try AgeFile.encrypt(body, to: [a.recipient])
        try plantedBytes.write(to: plantedURL)

        let report = try vault.addRecipient(b.recipient, label: "B")
        XCTAssertEqual(report.failures, ["\(testNote.uuidString.lowercased())/\(planted.filename)": .tagMismatch])
        XCTAssertEqual(report.rewrapped.count, revs.count)
        XCTAssertEqual(try Data(contentsOf: plantedURL), plantedBytes, "planted file untouched")
    }
}

