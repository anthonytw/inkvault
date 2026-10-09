import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The app's side of authenticated recipients (format.md §2.1): the one-time
/// upgrade at unlock, the blocking "device list was changed without its key"
/// alert with Remove (repair) and Cancel, no writes and no capture profile
/// for a tampered list.
@Suite(.serialized)
@MainActor
struct RecipientsAlertTests {
    enum Tamper: CaseIterable {
        case addedRecipient, removedRecipient, reordered, tagStripped, tagFromAnotherVault, secretReplaced
    }

    /// The tampers of `RecipientsTamper` (SempereTests), on vault.json.
    static func tamper(_ kind: Tamper, vault: URL, attacker: NativeRecipient) throws {
        let url = vault.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        switch kind {
        case .addedRecipient: m.recipients.append(.init(key: attacker.string, label: "New iPad", added: Date()))
        case .removedRecipient: m.recipients.removeLast()
        case .reordered: m.recipients.reverse()
        case .tagStripped: m.recipientsTag = nil
        case .tagFromAnotherVault: m.recipientsTag = String(repeating: "ab", count: 32)
        case .secretReplaced:
            let forged = VaultSecret.random()
            m.recipients.append(.init(key: attacker.string, label: "iPad", added: Date()))
            let keys = try m.recipients.map { try NativeRecipient(string: $0.key) }
            m.vaultSecret = String(decoding: try AgeFile.encrypt(forged.bytes, to: keys, armor: true), as: UTF8.self)
            m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: m.recipients.map(\.key), secret: forged)
            m.tagMarkers(secret: forged)   // the markers re-tagged under it too
        }
        try m.encoded().write(to: url)
    }

    /// The fixture (untagged) unlocked once: upgraded and reported, then
    /// given a second device key, all with `trust` as this device's records.
    static func preparedVault(trust: MemoryRecipientsTrustStore) async throws -> (url: URL, keyText: String) {
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        // As written before format.md §2.1 (the committed fixture is tagged).
        let manifestURL = url.appendingPathComponent("vault.json")
        var old = try VaultManifest.decode(Data(contentsOf: manifestURL))
        old.recipientsTag = nil
        old.features.removeAll { $0 == VaultManifest.recipientsTagFeature }
        old.markersTag = nil   // older than version markers too (format.md §2.1)
        old.features.removeAll { $0 == VaultManifest.markersTagFeature }
        try old.encoded().write(to: manifestURL)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.recipientsNotice?.contains("now protected") == true, "the one-time upgrade is reported")
        #expect(model.recipientsAlert == nil)
        #expect(try VaultManifest.decode(Data(contentsOf: url.appendingPathComponent("vault.json"))).recipientsTag != nil)
        try await model.addDeviceKey(recipient: try NativeIdentity.generate(.postQuantum).recipient.string, label: "Tablet", authenticator: PassingOwnerAuthenticator())
        model.close()
        // Unlocked again: verified, nothing to report.
        let again = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        try await again.openVault(at: url)
        try await again.unlock(identityText: keyText)
        #expect(again.recipientsNotice == nil, "once")
        #expect(again.recipientsAlert == nil)
        again.close()
        return (url, keyText)
    }

    /// Signed secret links (format.md §2.1): unlocking a vault an older
    /// writer left (no `signed-secret-link`, a legacy HMAC link) upgrades it
    /// and this device's record once, without asking.
    @Test func unlockUpgradesToSignedSecretLinks() async throws {
        guard postQuantumAvailable else { return }
        let trust = MemoryRecipientsTrustStore()
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        let manifestURL = url.appendingPathComponent("vault.json")
        var old = try VaultManifest.decode(Data(contentsOf: manifestURL))
        old.features.removeAll { $0 == VaultManifest.signedLinkFeature }
        old.secretLink = .legacy(String(repeating: "cd", count: 32))
        old.markersTag = nil   // an older writer kept no markers tag
        old.features.removeAll { $0 == VaultManifest.markersTagFeature }
        try old.encoded().write(to: manifestURL)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.recipientsAlert == nil)
        let now = try VaultManifest.decode(Data(contentsOf: manifestURL))
        #expect(now.secretLink == nil, "the legacy link is retired")
        #expect(now.features.contains(VaultManifest.signedLinkFeature))
        #expect(now.markersTag != nil, "the markers are tagged at unlock too (N3)")
        let record = try #require(try trust.record(for: now.vaultId))
        #expect(!record.isLegacy)
        #expect(model.vault?.secretLinkStatus.needsUpgrade == false)
        model.close()
    }

    /// Security review 2026-10 (R5): this device's record unreadable is not
    /// "first use": the alert offers Trust This List (not Remove), and
    /// confirming writes the record again and closes the alert.
    @Test func anUnreadableTrustRecordAsksToTrustTheList() async throws {
        let trust = MemoryRecipientsTrustStore()
        let (url, keyText) = try await Self.preparedVault(trust: trust)
        let vaultId = try Vault.open(at: url).vaultId
        trust.markUnreadable(vaultId, "damaged")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let alert = try #require(model.recipientsAlert)
        #expect(alert.problem.reason == .recordUnreadable)
        #expect(alert.canConfirm)
        #expect(!alert.canRemove)
        #expect(alert.message.contains("Trust This List"))
        try await model.confirmRecipientsList()
        #expect(model.recipientsAlert == nil)
        #expect(try trust.record(for: vaultId)?.recipients.count == 2)
        model.close()
    }

    @Test func tamperedListsRaiseTheAlertAndBlockWrites() async throws {
        for kind in Tamper.allCases {
            let trust = MemoryRecipientsTrustStore()
            let (url, keyText) = try await Self.preparedVault(trust: trust)
            let attacker = try NativeIdentity.generate(.postQuantum).recipient
            try Self.tamper(kind, vault: url, attacker: attacker)

            let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
            let qc = QuickCapture()
            qc.store = MemoryCaptureProfileStore()
            qc.showsActivity = false
            model.quickCapture = qc
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText, awaitNotes: false)
            let alert = try #require(model.recipientsAlert, "\(kind)")
            #expect(alert.unexpected.contains { $0.key == attacker.string } == [.addedRecipient, .secretReplaced].contains(kind))
            #expect(alert.canRemove == (kind != .secretReplaced), "\(kind)")
            #expect(alert.message.contains("Nothing is written"))
            if kind == .addedRecipient { #expect(alert.message.contains("New iPad")) }

            // Nothing is written, and no capture profile is made from the list.
            await #expect(throws: (any Error).self) {
                try await model.createNote(title: "x", paper: .blank, notebook: nil)
            }
            #expect(throws: (any Error).self) { try model.enableQuickCapture() }
            #expect(try qc.store.load() == nil)

            if alert.canRemove {
                try await model.repairRecipients()
                #expect(model.recipientsAlert == nil, "\(kind)")
                let keys = try #require(model.vault?.recipients.map(\.key))
                #expect(!keys.contains(attacker.string))
                #expect(keys.count == 2, "\(kind): the last verified list")
                _ = try await model.createNote(title: "After repair", paper: .blank, notebook: nil)
                try model.enableQuickCapture()
                #expect(try qc.store.load()?.profile.recipients == keys)
            } else {
                model.dismissRecipientsAlert()
                #expect(model.recipientsAlert == nil)
                #expect(model.vault?.recipientsStatus.allowsWriting == false, "Cancel writes nothing")
            }
            model.close()
        }
    }

    /// A profile made while the list checked is never refreshed from a list
    /// that does not.
    @Test func quickCaptureProfileKeepsTheVerifiedList() async throws {
        let trust = MemoryRecipientsTrustStore()
        let (url, keyText) = try await Self.preparedVault(trust: trust)
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        try model.enableQuickCapture()
        let before = try #require(try qc.store.load()).profile.recipients
        model.close()

        let attacker = try NativeIdentity.generate(.postQuantum).recipient
        try Self.tamper(.addedRecipient, vault: url, attacker: attacker)
        let tampered = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
        tampered.quickCapture = qc
        try await tampered.openVault(at: url)
        try await tampered.unlock(identityText: keyText, awaitNotes: false)
        tampered.refreshQuickCaptureProfile()
        #expect(try qc.store.load()?.profile.recipients == before)
        #expect(try qc.store.load()?.profile.recipients.contains(attacker.string) == false)
        tampered.close()
    }

    @Test func alertTextNamesTheUnknownDevices() throws {
        let key = try NativeIdentity.generate(.postQuantum).recipient.string
        let problem = RecipientsProblem(reason: .tagMismatch, unexpected: [key], missing: [], restore: ["age1pq1x"])
        let alert = RecipientsAlert(problem: problem, entries: [.init(key: key, label: "Mallory's phone", added: Date())])
        #expect(RecipientsAlert.title == "This vault's device list was changed without its key")
        #expect(alert.message.contains("Mallory's phone (age1pq1"))
        #expect(alert.canRemove)
        let replaced = RecipientsAlert(problem: .init(reason: .secretUnconfirmed, unexpected: [key], missing: [], restore: nil),
                                       entries: [])
        #expect(!replaced.canRemove)
        #expect(replaced.message.contains("backup"))
        #expect(replaced.displayTitle == RecipientsAlert.title)
    }

    /// Version markers changed without the key (format.md §2.1, security
    /// review 2026-10, N3): their own title and repair, no device list.
    @Test func markersAlertPointsToTheMarkersRepair() {
        for reason in [RecipientsProblem.Reason.markersMismatch, .markersRemoved, .markersRolledBack] {
            let alert = RecipientsAlert(problem: .init(reason: reason, unexpected: [], missing: [], restore: nil), entries: [])
            #expect(alert.displayTitle == RecipientsAlert.markersTitle)
            #expect(alert.message.contains("sempere vault markers repair"))
            #expect(!alert.message.contains("unknown device"))
            #expect(!alert.canRemove)
            #expect(!alert.canConfirm)
        }
    }

    /// Who captured a voice note, in its recording menu (format.md §8.3.1).
    @Test func capturedByNamesTheDevice() throws {
        let key = try NativeIdentity.generate(.postQuantum).recipient.string
        let entries: [VaultManifest.Recipient] = [.init(key: key, label: "iPad", added: Date())]
        var r = Recording(blob: BlobRef(content: Data([1]), type: "audio/mp4"), started: Date())
        #expect(RecordingsMenu.capturedBy(r, recipients: entries) == nil)
        r.captured = CaptureAttribution(device: "0b0b0b0b", recipient: CaptureKey.fingerprint(of: key))
        #expect(RecordingsMenu.capturedBy(r, recipients: entries) == "Voice note from iPad")
        #expect(RecordingsMenu.capturedBy(r, recipients: []) == "Voice note from a device no longer in this vault")
        r.captured?.recipient = nil
        #expect(RecordingsMenu.capturedBy(r, recipients: entries) == "Voice note from an unverified device")
    }
}
