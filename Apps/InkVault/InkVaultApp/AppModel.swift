import Age
import Foundation
import InkVault
import Observation

/// What the sidebar has selected; filters the note list.
enum SidebarItem: Hashable, Sendable {
    case allNotes
    case notebook(String)
    case tag(String)
    case deleted
}

/// Window-level state: the open vault, its note summaries and the current
/// selection. Vault I/O runs off the main actor; results land here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// No vault chosen.
        case noVault
        /// A vault is open by name only; notes need a key.
        case locked
        /// Notes are readable.
        case unlocked
    }

    /// Errors the shell reports to the user.
    enum ModelError: Error, Equatable, CustomStringConvertible {
        case noVaultOpen
        case notAnIdentity
        case noStoredKeys
        case passphraseMatchesNoKey

        var description: String {
            switch self {
            case .noVaultOpen: return "No vault is open."
            case .notAnIdentity: return "That text holds no AGE-SECRET-KEY-1… identity."
            case .noStoredKeys: return "This vault has no passphrase-protected key file."
            case .passphraseMatchesNoKey: return "The passphrase opens none of this vault's key files."
            }
        }
    }

    private(set) var phase: Phase = .noVault
    /// The open vault's folder.
    private(set) var vaultURL: URL?
    /// Every note in the vault, deleted ones included, sorted by title.
    private(set) var notes: [NoteSummary] = []
    /// True while vault I/O is in flight.
    private(set) var isBusy = false
    /// The last error, as a sentence for an alert; cleared by the view.
    var errorMessage: String?

    var sidebarSelection: SidebarItem? = .allNotes
    var selectedNoteID: UUID?

    private var vault: Vault?
    private var scopedURL: URL?

    init() {}

    // MARK: - Derived

    /// The vault's display name (folder name without `.inkvault`).
    var vaultName: String? {
        vaultURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Notebook names in use by live notes, sorted.
    var notebooks: [String] {
        Set(notes.filter { !$0.deleted }.compactMap(\.notebook)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tags in use by live notes, sorted.
    var tags: [String] {
        Set(notes.filter { !$0.deleted }.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The note list for the current sidebar selection.
    var visibleNotes: [NoteSummary] {
        switch sidebarSelection ?? .allNotes {
        case .allNotes: return notes.filter { !$0.deleted }
        case .notebook(let n): return notes.filter { !$0.deleted && $0.notebook == n }
        case .tag(let t): return notes.filter { !$0.deleted && $0.tags.contains(t) }
        case .deleted: return notes.filter(\.deleted)
        }
    }

    var selectedNote: NoteSummary? {
        selectedNoteID.flatMap { id in notes.first { $0.id == id } }
    }

    // MARK: - Opening and unlocking

    /// Opens the vault at `url` by name only (no key yet). Starts
    /// security-scoped access for URLs from the document picker and keeps
    /// it until the vault is closed.
    func openVault(at url: URL) async throws {
        close()
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let opened = try await Self.offMain { try Vault.open(at: url) }
            if scoped { scopedURL = url }
            vault = opened
            vaultURL = url
            phase = .locked
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Opens the vault at `url` and unlocks it with `identities` in one step.
    func openVault(at url: URL, identities: [any AgeIdentity]) async throws {
        try await openVault(at: url)
        try await unlock(with: identities)
    }

    /// Unlocks the open vault with age identities and loads the note list.
    func unlock(with identities: [any AgeIdentity]) async throws {
        guard let url = vaultURL else { throw ModelError.noVaultOpen }
        let opened = try await Self.offMain { try Vault.open(at: url, identities: identities) }
        vault = opened
        phase = .unlocked
        try await reload()
    }

    /// Unlocks with the text of an identity file (or a bare
    /// `AGE-SECRET-KEY-1…` line).
    func unlock(identityText: String) async throws {
        let identity: X25519Identity
        do { identity = try IdentityFile.parse(identityText) } catch { throw ModelError.notAnIdentity }
        try await unlock(with: [identity])
    }

    /// Unlocks with the passphrase of one of the vault's stored key files
    /// (`keys/<recipient>.key.age`, format.md §3.2).
    func unlock(passphrase: String) async throws {
        guard let locked = vault else { throw ModelError.noVaultOpen }
        let identity: X25519Identity = try await Self.offMain {
            let stored = try locked.identityFiles()
            guard !stored.isEmpty else { throw ModelError.noStoredKeys }
            for recipient in stored {
                do { return try locked.readIdentityFile(recipient: recipient, passphrase: passphrase) } catch VaultError.wrongPassphrase {
                    continue
                }
            }
            throw ModelError.passphraseMatchesNoKey
        }
        try await unlock(with: [identity])
    }

    /// Re-reads every note summary from disk.
    func reload() async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        isBusy = true
        defer { isBusy = false }
        notes = try await Self.offMain { try vault.summaries() }
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
    }

    /// Forgets the vault (and its keys) and releases folder access.
    func close() {
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        vault = nil
        vaultURL = nil
        notes = []
        selectedNoteID = nil
        sidebarSelection = .allNotes
        phase = .noVault
    }

    /// Runs `body` and records its error for the UI instead of throwing.
    func report(_ body: () async throws -> Void) async {
        do { try await body() } catch { errorMessage = "\(error)" }
    }

    /// Runs blocking vault work (file I/O, decryption) on a background thread.
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
