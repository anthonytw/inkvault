import Age
import Foundation
import InkVault
import Testing
@testable import InkVaultApp

/// An in-memory `VaultKeyStore`: what the Keychain store does, minus the
/// Keychain. `authorize` stands in for Face ID / the passcode.
actor FakeKeyStore: VaultKeyStore {
    struct Item: Equatable {
        var identity: String
        var name: String
        var storage: KeyStorage
    }

    private(set) var items: [UUID: Item] = [:]
    private(set) var reads = 0
    /// Thrown by the next authentication (`.cancelled`, `.authenticationFailed`), if set.
    var authError: KeyStoreError?
    var saveError: KeyStoreError?

    func setAuthError(_ e: KeyStoreError?) { authError = e }
    func setSaveError(_ e: KeyStoreError?) { saveError = e }
    func put(_ identity: String, for id: UUID, storage: KeyStorage = .thisDevice) {
        items[id] = Item(identity: identity, name: "test", storage: storage)
    }

    func storage(for vaultID: UUID) async throws -> KeyStorage? { items[vaultID]?.storage }

    func readKey(for vaultID: UUID, reason: String) async throws -> String {
        reads += 1
        if let authError { throw authError }
        guard let item = items[vaultID] else { throw KeyStoreError.notFound }
        return item.identity
    }

    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws {
        if let saveError { throw saveError }
        items[vaultID] = Item(identity: identity, name: vaultName, storage: storage)
    }

    func deleteKey(for vaultID: UUID) async throws { items[vaultID] = nil }
}

@MainActor
struct RememberedKeysTests {
    static func lockedModel() async throws -> (AppModel, key: String) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        return (model, try String(contentsOf: keyURL, encoding: .utf8))
    }

    @Test func manualUnlockOffersToRememberThenRemembers() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .noKey)
        #expect(model.phase == .locked)

        try await keys.unlock(model, identityText: key)
        #expect(model.phase == .unlocked)
        let offer = try #require(keys.offer)
        let vaultID = try #require(model.vault?.vaultId)
        #expect(offer.vaultID == vaultID)
        #expect(offer.vaultName == "sample")
        // The canonical key line only, not the file's comments.
        #expect(offer.identity == (try IdentityFile.parse(key)).string)
        #expect(keys.holdsUnlockSheet(model))

        try await keys.answer(offer, storage: .thisDevice)
        #expect(keys.offer == nil)
        #expect(!keys.holdsUnlockSheet(model))
        #expect(await store.items[vaultID] == FakeKeyStore.Item(identity: offer.identity, name: "sample", storage: .thisDevice))
        #expect(keys.storage(for: model) == .thisDevice)
    }

    @Test func declinedOfferStoresNothing() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        try await keys.unlock(model, identityText: key)
        try await keys.answer(try #require(keys.offer), storage: nil)
        #expect(keys.offer == nil)
        #expect(await store.items.isEmpty)
    }

    @Test func rememberedKeyUnlocksAfterAuthentication() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID, storage: .iCloudKeychain)
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(model.phase == .unlocked)
        #expect(await store.reads == 1)
        #expect(keys.storage(for: model) == .iCloudKeychain)
        #expect(keys.offer == nil)
        #expect(!keys.holdsUnlockSheet(model))
    }

    @Test func cancelledFaceIDFallsBackWithoutAnOffer() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID)
        await store.setAuthError(.cancelled)
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .cancelled)
        #expect(model.phase == .locked)
        // The user pastes the key instead: it is remembered already, so no offer.
        try await keys.unlock(model, identityText: key)
        #expect(model.phase == .unlocked)
        #expect(keys.offer == nil)
    }

    @Test func aWrongRememberedKeyFailsAndIsOfferedForReplacement() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put(X25519Identity().string, for: vaultID)
        let keys = RememberedKeys(store: store)
        guard case .failed = await keys.unlockWithRememberedKey(model) else {
            Issue.record("a key that opens nothing must fail")
            return
        }
        #expect(model.phase == .locked)
        try await keys.unlock(model, identityText: key)
        let offer = try #require(keys.offer)   // replaces the broken one
        try await keys.answer(offer, storage: .thisDevice)
        #expect(await store.items[vaultID]?.identity == offer.identity)
    }

    @Test func passphraseUnlockOffersTheKeyItOpened() async throws {
        // The fixture's key file holds its identity under `inkvault-test` (Fixtures/README.md).
        let (model, key) = try await Self.lockedModel()
        let identity = try IdentityFile.parse(key)
        let keys = RememberedKeys(store: FakeKeyStore())
        try await keys.unlock(model, passphrase: "inkvault-test")
        #expect(keys.offer?.identity == identity.string)
    }

    @Test func forgetDeletesAndAClosedVaultDropsTheOffer() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        try await keys.unlock(model, identityText: key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        try await keys.forget(model)
        #expect(await store.items.isEmpty)
        #expect(keys.storage(for: model) == nil)

        // An offer left open when the vault closes is dropped (the key leaves memory).
        let (other, otherKey) = try await Self.lockedModel()
        try await keys.unlock(other, identityText: otherKey)
        #expect(keys.offer != nil)
        other.close()
        keys.discardStaleOffer(other)
        #expect(keys.offer == nil)
    }

    @Test func aCloseDuringFaceIDDoesNotUnlock() async throws {
        let (model, key) = try await Self.lockedModel()
        let store = FakeKeyStore()
        let vaultID = try #require(model.vault?.vaultId)
        await store.put((try IdentityFile.parse(key)).string, for: vaultID)
        let keys = RememberedKeys(store: store)
        let attempt = Task { await keys.unlockWithRememberedKey(model) }
        model.close()
        let result = await attempt.value
        #expect(result == .cancelled || result == .noKey)
        #expect(model.phase == .noVault)
    }
}
