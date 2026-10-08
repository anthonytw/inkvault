import Foundation
import Sempere

/// The blocking alert for a vault whose `vault.json` recipients do not check
/// (format.md §2.1): "This vault's device list was changed without its key".
/// Remove rewrites the last verified list and rotates the vault secret
/// (`Vault.repairRecipients`); Cancel leaves the vault readable and unwritten.
struct RecipientsAlert: Identifiable, Equatable, Sendable {
    /// One recipient the alert names.
    struct Entry: Equatable, Sendable {
        var key: String
        var label: String

        /// `Label (age1pq1abcdefg…)`, or the abbreviated key alone.
        var display: String {
            let short = RecipientsProblem.abbreviate(key)
            return label.isEmpty ? short : "\(label) (\(short))"
        }
    }

    let id = UUID()
    var problem: RecipientsProblem
    /// The keys listed now that are not in the last verified list.
    var unexpected: [Entry]

    init(problem: RecipientsProblem, entries: [VaultManifest.Recipient]) {
        self.problem = problem
        let labels = Dictionary(entries.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
        unexpected = problem.unexpected.map { Entry(key: $0, label: labels[$0] ?? "") }
    }

    static let title = String(localized: "This vault's device list was changed without its key", comment: "Alert title: vault.json's recipients were edited without the vault key")

    /// Remove is offered when the library can write the last verified list:
    /// not after an unconfirmed secret change (the files are tagged under a
    /// secret this device no longer holds), nor when no list is known.
    var canRemove: Bool { problem.reason != .secretUnconfirmed && problem.restore != nil }

    /// The alert's text: what happened, the unknown devices, what Remove does.
    var message: String {
        var lines: [String] = []
        switch problem.reason {
        case .tagMismatch:
            lines.append(String(localized: "Someone who can change the vault's folder (a sync service, a shared folder) edited its list of devices without the vault's key."))
        case .tagRemoved:
            lines.append(String(localized: "The list of devices lost its authentication: someone who can change the vault's folder removed it."))
        case .secretUnconfirmed:
            lines.append(String(localized: "The vault's key was replaced in a way this device cannot confirm."))
        }
        if unexpected.isEmpty {
            lines.append(String(localized: "No unknown device was added, but the list is not the one this device last checked."))
        } else {
            let devices = unexpected.map(\.display).joined(separator: ", ")
            lines.append(String(localized: "Devices this device never confirmed: \(devices).", comment: "The value is a list of device names and abbreviated keys"))
        }
        lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until the list is fixed."))
        if canRemove {
            lines.append(String(localized: "Remove restores the last checked list and re-encrypts every note with a new vault key, so no other device can read them."))
        } else if problem.reason == .secretUnconfirmed {
            lines.append(String(localized: "If you changed the vault's keys on another device, open the vault there, or check the list with `sempere vault recipients confirm`. Otherwise restore vault.json from a backup."))
        } else {
            lines.append(String(localized: "Repair it from a device that has opened this vault before, or with `sempere vault recipients repair --keep`."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The one-time report of an untagged vault's upgrade.
    static func upgradeNotice(_ recipients: [VaultManifest.Recipient]) -> String {
        let names = recipients.map { Entry(key: $0.key, label: $0.label).display }
        let list = names.joined(separator: ", ")
        return String(localized: "This vault's list of devices is now protected: a change made without the vault's key will be detected. It trusts these \(recipients.count) devices: \(list). If one is not yours, remove it in Keys.",
                      comment: "Notice after unlocking; the values are the number of devices and their names")
    }
}

extension AppModel {
    /// Remove in the alert: rewrites the last verified list and rotates the
    /// vault secret, re-encrypting every note (format.md §2.1 "Repair"), as a
    /// key change (editors closed first, `keyEpoch` bumped).
    func repairRecipients() async throws {
        guard let alert = recipientsAlert, alert.canRemove else { return }
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.repairRecipients(policy: policy) }
        if vault?.recipientsStatus.problem == nil { recipientsAlert = nil }
    }

    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `untrustedRecipients` until it is repaired.
    func dismissRecipientsAlert() {
        recipientsAlert = nil
    }
}
