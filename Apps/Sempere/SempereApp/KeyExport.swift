import Age
import Foundation
import LocalAuthentication
import Sempere
import SempereRender

/// A secret key on its way out of the app (Settings → Device Keys: Save Key…,
/// New Key…): the `age-keygen` style text `sempere keys generate` writes
/// (`IdentityFile.render`), the name to suggest, and what the recovery kit
/// needs. It lives in a view's state while the sheet is up and nowhere else.
struct KeyFile: Sendable, Equatable {
    /// The `AGE-SECRET-KEY-PQ-1…` line.
    var secret: String
    /// The `age1pq1…` recipient.
    var recipient: String
    /// The device label, as in the vault's key list.
    var label: String
    /// The file's text: `# created`, `# public key`, the secret line.
    var text: String

    init(identity: NativeIdentity, label: String, created: Date = Date()) {
        secret = identity.string
        recipient = identity.recipient.string
        self.label = label
        text = IdentityFile.render(identity, created: created)
    }

    /// `Sempere key - <label>.txt`.
    var fileName: String { IdentityFile.exportFileName(label: label) }
}

/// Asks the device owner to prove they are there before a secret key leaves
/// the app. Tests inject a fake.
protocol OwnerAuthenticator: Sendable {
    func authenticate(reason: String) async throws
}

/// Face ID or Touch ID when enrolled, with no passcode fallback (as for
/// device-only remembered keys, `RememberedKeys.deviceOnlyFooter`); the
/// passcode (or the Mac's password) only on a device without biometrics.
struct SystemOwnerAuthenticator: OwnerAuthenticator {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: nil) else { throw AppModel.KeyExportError.noDeviceLock }
        do {
            _ = try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            throw CancellationError()
        } catch {
            throw AppModel.KeyExportError.notAuthenticated
        }
    }
}

/// A plaintext key file handed to the share sheet: the share sheet takes
/// files by URL, so this is the one place a key is written by the app. It goes
/// to `<tmp>/SempereKeyShare/<uuid>/<name>` (file protection complete, mode
/// 0600) and is deleted when the share sheet closes, when the sheet that
/// staged it goes away, and at launch. "Save to Files" needs no file: it
/// writes the text straight to the folder the user picks.
enum KeyShareFile {
    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereKeyShare", isDirectory: true)
    }

    /// Writes `key` for the share sheet, after removing any earlier one.
    static func stage(_ key: KeyFile, in root: URL = KeyShareFile.root) throws -> URL {
        purge(in: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(key.fileName)
        #if os(iOS)
        try Data(key.text.utf8).write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        #else
        try Data(key.text.utf8).write(to: url, options: [.withoutOverwriting])
        #endif
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Deletes every staged key file.
    nonisolated static func purge(in root: URL = KeyShareFile.root) {
        try? FileManager.default.removeItem(at: root)
    }
}

extension AppModel {
    enum KeyExportError: Error, Equatable, CustomStringConvertible {
        case notAuthenticated
        case noDeviceLock

        var description: String {
            switch self {
            case .notAuthenticated: return "Sempere could not confirm it is you, so the key was not shown."
            case .noDeviceLock: return "Set a passcode (or Face ID or Touch ID) on this device to save its key."
            }
        }
    }

    /// The post-quantum key this vault was unlocked with (one of its recipients).
    var heldIdentity: NativeIdentity? {
        guard let vault else { return nil }
        let listed = Set(vault.recipients.map(\.key))
        return unlockIdentities.compactMap { $0 as? NativeIdentity }
            .first { $0.isPostQuantum && listed.contains($0.recipient.string) }
    }

    /// This device's key (the one the vault was unlocked with) as a key file,
    /// after the owner authenticates. The CLI's counterpart is the identity file
    /// itself, or `sempere keys export` from the vault's passphrase-wrapped copy.
    func exportThisDeviceKey(authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws -> KeyFile {
        guard let vault, phase == .unlocked, let identity = heldIdentity else {
            throw phase == .unlocked ? KeyError.noIdentity : KeyError.notUnlocked
        }
        let vaultID = vault.vaultId
        let gen = generation
        try await authenticator.authenticate(reason: "Save the key of “\(vaultName ?? "this vault")”")
        // Another vault opened, or this one locked, while the prompt was up.
        guard gen == generation, self.vault?.vaultId == vaultID, phase == .unlocked else { throw KeyError.vaultChanged }
        let label = vault.recipients.first { $0.key == identity.recipient.string }?.label ?? "Device"
        return KeyFile(identity: identity, label: label)
    }

    /// The recovery kit of `key`, one of this vault's keys (`sempere keys paper --vault`).
    func recoveryKitPDF(for key: KeyFile, a4: Bool = false) throws -> Data {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        guard vault.recipients.contains(where: { $0.key == key.recipient }) else { throw KeyError.notListed }
        return try recoveryKit(secret: key.secret, recipient: key.recipient, a4: a4)
    }
}
