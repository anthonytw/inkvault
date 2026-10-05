import Foundation
import LocalAuthentication
import Security

/// Where a remembered vault key lives.
enum KeyStorage: String, Sendable, Equatable {
    /// This device's Keychain only, readable after Face ID / Touch ID (or the
    /// passcode when no biometrics are enrolled), enforced by the Keychain.
    case thisDevice
    /// iCloud Keychain, synced to the user's other devices. The Keychain
    /// cannot put biometrics on a synchronizable item, so the app asks for
    /// Face ID or the passcode (`LAContext`) before it reads one.
    case iCloudKeychain
}

/// Why a remembered key could not be stored or read.
enum KeyStoreError: Error, Equatable, CustomStringConvertible {
    /// No key is stored for the vault (or it was invalidated, e.g. by a Face ID
    /// enrollment change).
    case notFound
    /// The user cancelled Face ID / the passcode prompt.
    case cancelled
    case authenticationFailed
    /// The device has no passcode, so nothing can be protected by one.
    case noPasscode
    /// The build lacks the Keychain entitlement this needs (e.g. an unsigned build).
    case missingEntitlement
    case keychain(Int32)

    var description: String {
        switch self {
        case .notFound: return "No key is saved for this vault."
        case .cancelled: return "Authentication was cancelled."
        case .authenticationFailed: return "Authentication failed."
        case .noPasscode: return "Set a device passcode to let InkVault remember keys."
        case .missingEntitlement: return "This build of InkVault cannot use the Keychain (missing entitlement)."
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return "Keychain error \(status): \(text)"
        }
    }
}

/// Remembered vault keys: the age identity text (`AGE-SECRET-KEY-1…`) per
/// vault id (`vault.json`). The model talks to this protocol; tests use an
/// in-memory fake.
protocol VaultKeyStore: Sendable {
    /// Where the key for `vaultID` is stored, without reading it (no prompt);
    /// nil when there is none.
    func storage(for vaultID: UUID) async throws -> KeyStorage?
    /// Reads the key, after Face ID / Touch ID or the passcode. `reason` is
    /// shown in the prompt.
    func readKey(for vaultID: UUID, reason: String) async throws -> String
    /// Stores `identity` for the vault, replacing any key stored for it.
    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws
    /// Deletes the vault's key wherever it is stored; no error when there is none.
    func deleteKey(for vaultID: UUID) async throws
}

/// `VaultKeyStore` on the Keychain: one generic-password item per vault,
/// service `KeychainVaultKeyStore.service`, account the vault id, label
/// "InkVault — <vault name>".
///
/// - `thisDevice`: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with a
///   `SecAccessControl` of `.biometryCurrentSet` (Face ID / Touch ID; a new
///   enrollment invalidates the item), or `.userPresence` when no biometrics
///   are enrolled. Never leaves the device, not in backups either.
/// - `iCloudKeychain`: `kSecAttrSynchronizable`, `kSecAttrAccessibleWhenUnlocked`
///   (synchronizable items can be neither `ThisDeviceOnly` nor carry an access
///   control). Reading is gated by `LAContext.evaluatePolicy` in the app only.
///
/// No extra entitlement: items go to the app's default access group (its
/// application identifier, which every signed build has, the free personal
/// team's included). Mac Catalyst uses the data protection keychain, which
/// needs a signed build; an unsigned one gets `errSecMissingEntitlement`.
/// The key is never logged and never written anywhere but the Keychain.
struct KeychainVaultKeyStore: VaultKeyStore {
    static let service = "io.github.anthonytw.inkvault.vault-key"

    private static func baseQuery(_ vaultID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vaultID.uuidString.lowercased(),
         kSecUseDataProtectionKeychain as String: true]
    }

    func storage(for vaultID: UUID) async throws -> KeyStorage? {
        try await Task.detached(priority: .userInitiated) { () throws -> KeyStorage? in
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true   // attributes only: never prompt
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                let attributes = result as? [String: Any]
                let synced = (attributes?[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
                return synced ? .iCloudKeychain : .thisDevice
            case errSecInteractionNotAllowed:
                return .thisDevice   // exists, behind an access control
            case errSecItemNotFound:
                return nil
            default:
                throw Self.error(status)
            }
        }.value
    }

    func readKey(for vaultID: UUID, reason: String) async throws -> String {
        guard let storage = try await storage(for: vaultID) else { throw KeyStoreError.notFound }
        let context = LAContext()
        context.localizedReason = reason
        if storage == .iCloudKeychain {
            // The item has no access control: the app asks before reading it.
            do {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch let error as LAError {
                switch error.code {
                case .userCancel, .appCancel, .systemCancel, .userFallback: throw KeyStoreError.cancelled
                case .passcodeNotSet: throw KeyStoreError.noPasscode
                default: throw KeyStoreError.authenticationFailed
                }
            }
        }
        let box = ContextBox(context)
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = storage == .iCloudKeychain
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = box.context   // the device-only item prompts here
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { throw Self.error(status) }
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                throw KeyStoreError.notFound
            }
            return text
        }.value
    }

    func save(_ identity: String, for vaultID: UUID, vaultName: String, storage: KeyStorage) async throws {
        let canBiometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let hasPasscode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        guard hasPasscode else { throw KeyStoreError.noPasscode }
        try await deleteKey(for: vaultID)
        try await Task.detached(priority: .userInitiated) {
            var item = Self.baseQuery(vaultID)
            item[kSecAttrLabel as String] = "InkVault — \(vaultName)"
            item[kSecAttrDescription as String] = "InkVault vault key"
            item[kSecAttrComment as String] = "age identity that opens the InkVault vault “\(vaultName)”"
            item[kSecValueData as String] = Data(identity.utf8)
            switch storage {
            case .thisDevice:
                var cfError: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    canBiometrics ? .biometryCurrentSet : .userPresence, &cfError)
                else {
                    cfError?.release()
                    throw KeyStoreError.keychain(errSecParam)
                }
                item[kSecAttrAccessControl as String] = access
            case .iCloudKeychain:
                item[kSecAttrSynchronizable as String] = true
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.error(status) }
        }.value
    }

    func deleteKey(for vaultID: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            var query = Self.baseQuery(vaultID)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        }.value
    }

    static func error(_ status: OSStatus) -> KeyStoreError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecUserCanceled: return .cancelled
        case errSecAuthFailed: return .authenticationFailed
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .keychain(status)
        }
    }
}

/// Hands an `LAContext` (not `Sendable`) to the Keychain call that uses it;
/// nothing else touches it meanwhile.
private final class ContextBox: @unchecked Sendable {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}
