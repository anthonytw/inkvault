import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The key window's model: list, add, generate, remove, recovery kit.
@MainActor
struct KeyManagementTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> (AppModel, URL) {
        try await NoteWindowTests.unlockedModel()
    }

    @Test func listsTheVaultsKeysAndMarksTheOneInUse() async throws {
        let (model, _) = try await Self.unlockedModel()
        let keys = model.deviceKeys
        #expect(keys.count == 1)
        #expect(keys[0].isInUse)
        #expect(keys[0].isPostQuantum)
        #expect(keys[0].recipient.hasPrefix("age1pq1"))
        #expect(keys[0].summary.count < 100, "the 1959-character key is abbreviated")
        #expect(keys[0].summary.contains("SHA-256"))
    }

    @Test func aPastedPublicKeyIsAddedAndOpensTheVault() async throws {
        let (model, url) = try await Self.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: "  \(other.recipient.string)\n", label: " Anna's iPad ")
        #expect(model.deviceKeys.count == 2)
        let added = try #require(model.deviceKeys.first { $0.recipient == other.recipient.string })
        #expect(added.label == "Anna's iPad")
        #expect(!added.isInUse)
        #expect(model.keyEpoch == 1)
        let vault = try Vault.open(at: url, identities: [other])
        #expect(try vault.summaries().count == 2, "the new key reads every note")
    }

    @Test func aGeneratedKeyIsAddedAndItsSecretReturnedOnce() async throws {
        let (model, url) = try await Self.unlockedModel()
        let secret = try await model.generateDeviceKey(label: "")
        let identity = try IdentityFile.parse(secret)
        #expect(identity.isPostQuantum)
        #expect(model.deviceKeys.map(\.label).contains("Device"))
        #expect(model.deviceKeys.contains { $0.recipient == identity.recipient.string })
        #expect(try Vault.open(at: url, identities: [identity]).summaries().count == 2)
    }

    @Test func removingAKeyLocksItOutAndKeepsTheOthers() async throws {
        let (model, url) = try await Self.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "Old iPad")
        try await model.removeDeviceKey(other.recipient.string)
        #expect(model.deviceKeys.count == 1)
        #expect(model.keyEpoch == 2)
        #expect(throws: (any Error).self) { _ = try Vault.open(at: url, identities: [other]).summaries() }
        let mine = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try mine.summaries().count == 2)
    }

    @Test func theKeyInUseAndTheLastKeyCannotBeRemoved() async throws {
        let (model, _) = try await Self.unlockedModel()
        let mine = model.deviceKeys[0].recipient
        await #expect(throws: AppModel.KeyError.lastKey) { try await model.removeDeviceKey(mine) }
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B")
        await #expect(throws: AppModel.KeyError.inUse) { try await model.removeDeviceKey(mine) }
        await #expect(throws: AppModel.KeyError.notListed) {
            try await model.removeDeviceKey(try NativeIdentity.generate(.postQuantum).recipient.string)
        }
    }

    @Test func badKeysAreRefusedBeforeAnythingChanges() async throws {
        let (model, _) = try await Self.unlockedModel()
        for text in ["", "hello", "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq", "AGE-SECRET-KEY-PQ-1ABC"] {
            await #expect(throws: AppModel.KeyError.notPostQuantum) { try await model.addDeviceKey(recipient: text, label: "x") }
        }
        await #expect(throws: AppModel.KeyError.alreadyListed) {
            try await model.addDeviceKey(recipient: model.deviceKeys[0].recipient, label: "again")
        }
        #expect(model.deviceKeys.count == 1)
        #expect(model.keyEpoch == 0)
    }

    @Test func keyChangesNeedAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let other = try NativeIdentity.generate(.postQuantum)
        await #expect(throws: AppModel.KeyError.notUnlocked) {
            try await model.addDeviceKey(recipient: other.recipient.string, label: "x")
        }
        await #expect(throws: AppModel.KeyError.notUnlocked) { _ = try await model.generateDeviceKey(label: "x") }
        await #expect(throws: AppModel.KeyError.notUnlocked) { _ = try model.recoveryKitPDF() }
        #expect(model.deviceKeys.isEmpty)
    }

    @Test func everyEditorIsClosedAndNotesWriteAgainAfterAKeyChange() async throws {
        let (model, url) = try await Self.unlockedModel()
        await model.claimNote(Self.lecture)
        let window = try await model.openWindowNote(Self.lecture)
        window.addPage()   // pending: saved before the vault changes
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B")
        #expect(model.windowEditors.isEmpty)
        #expect(model.editor == nil)
        var vault = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions).pages.count == 3)

        // A rotation (removal) changes the vault secret: a fresh editor writes with the new one.
        try await model.removeDeviceKey(other.recipient.string)
        let again = try await model.openWindowNote(Self.lecture)
        again.addPage()
        await again.flush()
        vault = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions).pages.count == 4)
        #expect(try vault.loadNote(Self.lecture).failures.isEmpty)
    }

    @Test func theRecoveryKitIsAPDFOfTheKeyInUse() async throws {
        let (model, _) = try await Self.unlockedModel()
        let letter = try model.recoveryKitPDF()
        let a4 = try model.recoveryKitPDF(a4: true)
        #expect(letter.starts(with: Data("%PDF-".utf8)))
        #expect(a4.starts(with: Data("%PDF-".utf8)))
        #expect(letter != a4)
    }

    @Test func labelsAreOneShortLine() {
        #expect(AppModel.cleanLabel("  Anna's\niPad  ") == "Anna's iPad")
        #expect(AppModel.cleanLabel("") == "Device")
        #expect(AppModel.cleanLabel("\n \n") == "Device")
        #expect(AppModel.cleanLabel(String(repeating: "x", count: 300)).count == 80)
    }
}
