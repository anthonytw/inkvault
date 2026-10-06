import Age
import Foundation
import InkVault
import LocalAuthentication
import Observation

/// Vault keys remembered in the Keychain (task 3d): offers to remember the key
/// after a manual unlock, unlocks with the remembered key (Face ID first) when
/// a vault opens, and forgets it on request.
///
/// Kept apart from `AppModel` (it only calls the model's unlock methods), so
/// the key store can be swapped for a fake in tests. The key text lives in
/// memory only while an offer is on screen; it is never logged and never
/// written anywhere but the key store.
@MainActor
@Observable
final class RememberedKeys {
    /// An unlock the user may want remembered.
    struct Offer: Identifiable, Equatable {
        let vaultID: UUID
        let vaultName: String
        /// The identity, `AGE-SECRET-KEY-PQ-1…` (or a legacy `AGE-SECRET-KEY-1…`).
        let identity: String
        var id: UUID { vaultID }
    }

    /// How an attempt to unlock with the remembered key ended.
    enum Attempt: Equatable {
        case unlocked
        /// Nothing is remembered for this vault (or it was invalidated).
        case noKey
        /// The user cancelled Face ID / the passcode, or the vault changed meanwhile.
        case cancelled
        /// A key was read but did not unlock the vault, or the Keychain failed.
        case failed(String)
    }

    let store: any VaultKeyStore
    /// Shown after a manual unlock until the user answers.
    var offer: Offer?
    /// Where the open vault's key is remembered (nil: not remembered, or not known yet).
    private(set) var storage: KeyStorage?
    /// The vault `storage` describes.
    private(set) var storageVaultID: UUID?
    /// True while Face ID / the Keychain is being asked.
    private(set) var isUnlocking = false
    /// True while an unlock with a passphrase or pasted key runs.
    private(set) var isManualUnlocking = false
    /// The remembered key was tried and does not work (wrong key, invalidated).
    private var brokenVaultID: UUID?

    init(store: any VaultKeyStore = KeychainVaultKeyStore()) {
        self.store = store
    }

    /// "this iPad", or "this Mac" under Mac Catalyst.
    static var deviceName: String {
        ProcessInfo.processInfo.isMacCatalystApp ? "this Mac" : "this iPad"
    }

    /// The device's biometry ("Face ID", "Touch ID", "Optic ID") when one is
    /// enrolled, else nil (a device-only key is then read with the passcode).
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// The footer under "Remember on this device". A device-only key is
    /// `.biometryCurrentSet` (`KeychainVaultKeyStore`): only that biometry
    /// reads it, never the passcode, so after a lockout the user unlocks with
    /// the key or passphrase. Without biometrics it is `.userPresence`.
    static func deviceOnlyFooter(vaultName: String, biometry: String?) -> String {
        let kept = "The key stays in this device's Keychain and is not included in backups."
        guard let biometry else {
            return "Next time, \(vaultName) opens after your device passcode. \(kept)"
        }
        return "Next time, \(vaultName) opens after \(biometry), and only \(biometry): the passcode cannot "
            + "read the saved key. If \(biometry) is locked out after failed attempts, turned off, or "
            + "re-enrolled, unlock with the key or the passphrase instead. \(kept)"
    }

    /// The remembered storage for the open vault, if known.
    func storage(for model: AppModel) -> KeyStorage? {
        guard let id = model.vault?.vaultId, storageVaultID == id else { return nil }
        return storage
    }

    /// Looks up (without reading or prompting) whether the open vault's key
    /// is remembered.
    func refresh(_ model: AppModel) async {
        guard let id = model.vault?.vaultId else { return }
        let found = try? await store.storage(for: id)
        guard model.vault?.vaultId == id else { return }
        storageVaultID = id
        storage = found
    }

    // MARK: - Unlocking

    /// Unlocks the locked vault with its remembered key: the key store asks
    /// for Face ID / Touch ID (or the passcode) first.
    func unlockWithRememberedKey(_ model: AppModel) async -> Attempt {
        guard model.phase == .locked, let vault = model.vault, !isUnlocking else { return .cancelled }
        let id = vault.vaultId
        let gen = model.generation
        isUnlocking = true
        defer { isUnlocking = false }
        let identity: String
        do {
            let stored = try await store.storage(for: id)
            try model.ensureCurrent(gen)
            storageVaultID = id
            storage = stored
            guard stored != nil else { return .noKey }
            let name = model.vaultName ?? "the vault"
            identity = try await store.readKey(for: id, reason: "Unlock “\(name)” with its saved key")
            try model.ensureCurrent(gen)
        } catch is CancellationError {
            return .cancelled
        } catch KeyStoreError.cancelled {
            return .cancelled
        } catch KeyStoreError.notFound {
            if model.vault?.vaultId == id { storage = nil }
            return .noKey
        } catch {
            // Face ID failed or the Keychain could not be read: the key itself
            // may be fine, so it is not marked broken (replacing it could
            // delete a working iCloud Keychain copy on every device).
            return .failed("The saved key could not be read: \(error)")
        }
        do {
            try await model.unlock(identityText: identity)
            brokenVaultID = nil
            return .unlocked
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Only a key that is not one, or that opens nothing, is broken; an
            // I/O failure (e.g. iCloud) says nothing about the key.
            if model.vault?.vaultId == id, Self.isWrongKey(error) { brokenVaultID = id }
            return .failed("The saved key did not unlock this vault: \(error)")
        }
    }

    /// Whether an unlock failed because of the key rather than the vault's files.
    static func isWrongKey(_ error: any Error) -> Bool {
        switch error {
        case AppModel.ModelError.notAnIdentity, VaultError.vaultSecretUndecryptable, VaultError.classicIdentity:
            return true
        default: return false
        }
    }

    /// Unlocks with pasted identity text, then offers to remember it.
    func unlock(_ model: AppModel, identityText: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        let identity = try await model.unlock(identityText: identityText)
        offerToRemember(identity, model)
    }

    /// Unlocks with a stored key file's passphrase, then offers to remember
    /// the key it holds.
    func unlock(_ model: AppModel, passphrase: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        let identity = try await model.unlock(passphrase: passphrase)
        offerToRemember(identity, model)
    }

    /// Whether the unlock sheet stays up although the vault is unlocked: a
    /// manual unlock is finishing (its offer comes next) or an offer is open.
    func holdsUnlockSheet(_ model: AppModel) -> Bool {
        if isManualUnlocking { return true }
        guard let offer else { return false }
        return model.phase == .unlocked && offer.vaultID == model.vault?.vaultId
    }

    /// Offers to remember `identity` unless a working key is already remembered.
    func offerToRemember(_ identity: NativeIdentity, _ model: AppModel) {
        guard model.phase == .unlocked, let id = model.vault?.vaultId else { return }
        if storageVaultID == id, storage != nil, brokenVaultID != id { return }
        offer = Offer(vaultID: id, vaultName: model.vaultName ?? "Vault", identity: identity.string)
    }

    // MARK: - Remembering and forgetting

    /// Answers the offer: nil does not remember the key. Clears the offer.
    func answer(_ offer: Offer, storage: KeyStorage?) async throws {
        if self.offer?.vaultID == offer.vaultID { self.offer = nil }
        guard let storage else { return }
        try await store.save(offer.identity, for: offer.vaultID, vaultName: offer.vaultName, storage: storage)
        storageVaultID = offer.vaultID
        self.storage = storage
        if brokenVaultID == offer.vaultID { brokenVaultID = nil }
    }

    /// Forgets the open vault's remembered key.
    func forget(_ model: AppModel) async throws {
        guard let id = model.vault?.vaultId else { return }
        try await store.deleteKey(for: id)
        if model.vault?.vaultId == id {
            storageVaultID = id
            storage = nil
        }
    }

    /// Drops an offer for a vault that is no longer open.
    func discardStaleOffer(_ model: AppModel) {
        if let offer, offer.vaultID != model.vault?.vaultId || model.phase != .unlocked { self.offer = nil }
    }
}
