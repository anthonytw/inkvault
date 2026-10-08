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

    /// Trust This List is offered when this device's own record of the list
    /// cannot be read (security review 2026-10, R5): the list itself checks
    /// under the vault's key, so after the user checked the devices the
    /// record is written again (`Vault.confirmRecipients`).
    var canConfirm: Bool { problem.reason == .recordUnreadable }

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
        case .recordUnreadable:
            lines.append(String(localized: "This device's record of the vault's devices cannot be read, so the list cannot be checked against it."))
        }
        if unexpected.isEmpty {
            lines.append(String(localized: "No unknown device was added, but the list is not the one this device last checked."))
        } else {
            let devices = unexpected.map(\.display).joined(separator: ", ")
            lines.append(String(localized: "Devices this device never confirmed: \(devices).", comment: "The value is a list of device names and abbreviated keys"))
        }
        lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until the list is fixed."))
        if canConfirm {
            lines.append(String(localized: "If every device listed is yours, Trust This List records it again on this device."))
        } else if canRemove {
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

    /// Trust This List in the alert (an unreadable trust record): records
    /// the current list again after the user checked it. Nothing in the
    /// vault changes unless the list was untagged (it is tagged then).
    /// As a key change (editors closed first, `keyEpoch` bumped), but
    /// without downloading the vault: no file under `notes/` changes.
    func confirmRecipientsList() async throws {
        guard let alert = recipientsAlert, alert.canConfirm, let start = vault, phase == .unlocked else { return }
        await editGate.acquire()
        defer { editGate.release() }
        let gen = generation
        try await openEditor(for: nil)   // saved, and closed: it holds the tampered status
        await closeWindowEditors()
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let next = try await offMain { () throws -> Vault in
            try CloudVault.coordinatedWrite(coordinate) { () throws -> Vault in
                var copy = start
                try copy.confirmRecipients()
                return copy
            }
        }
        try ensureCurrent(gen)
        adoptRewrapped(next)
    }

    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `untrustedRecipients` until it is repaired.
    func dismissRecipientsAlert() {
        recipientsAlert = nil
    }
}
