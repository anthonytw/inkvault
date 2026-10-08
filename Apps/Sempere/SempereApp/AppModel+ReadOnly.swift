import Foundation
import Sempere

/// Vaults holding content of a newer format version (format.md §7.3): the
/// app shows what it understands and writes nothing. The library refuses
/// every write of such a vault (`Vault.requireWritable`); the model refuses
/// earlier, so nothing starts that would fail half way, and the UI says why.
extension AppModel {
    /// Why the open vault is read-only: its manifest (a later `format`,
    /// unknown `features`) and the listed notes a newer version wrote. Empty
    /// when it can be changed. Observable through `vault` and `notes`.
    var readOnlyReasons: ReadOnlyReasons {
        var reasons = vault?.readOnlyReasons ?? ReadOnlyReasons()
        let listed = notes.lazy.filter { $0.newer != nil }.map(\.id)
        if !listed.isEmpty {
            reasons.newerNotes = Set(reasons.newerNotes).union(listed).sorted { $0.uuidString < $1.uuidString }
        }
        return reasons
    }

    /// True when nothing may be written to the open vault.
    var isVaultReadOnly: Bool { !readOnlyReasons.isEmpty }

    /// The banner over the note list of a read-only vault; nil when writable.
    var readOnlyBanner: String? {
        let reasons = readOnlyReasons
        guard !reasons.isEmpty else { return nil }
        return Self.readOnlyText(reasons)
    }

    /// "Written by a newer version of Sempere: …. Read-only: update Sempere to edit it."
    nonisolated static func readOnlyText(_ reasons: ReadOnlyReasons) -> String {
        let details = reasons.descriptions.joined(separator: "; ")
        return String(localized: "Read-only: \(details). Update Sempere to change this vault.")
    }

    /// Throws `VaultError.readOnly` for a read-only vault (format.md §7.3).
    func requireWritableVault() throws {
        let reasons = readOnlyReasons
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
    }
}
