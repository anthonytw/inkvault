import Age
import Foundation
import InkVault

/// Vault browsing: opening and creating vaults, and the sidebar's edits.
/// Every edit is one delta per note, written through `Vault.apply`; the
/// app never writes vault files itself.
extension AppModel {
    nonisolated static let appName = "inkvault-app/0.1"

    // MARK: - Opening and creating

    /// Opens a folder chosen in the document picker and remembers it.
    func open(picked url: URL, library: VaultLibrary) async throws {
        try await openVault(at: url)
        remember(in: library)
    }

    /// Reopens a recent vault from its bookmark.
    ///
    /// - Throws: `VaultLibrary.LibraryError.cannotResolve` when the bookmark
    ///   is dead (the entry is dropped); otherwise whatever opening throws,
    ///   with the entry kept.
    func open(recent entry: RecentVault, library: VaultLibrary) async throws {
        let url = try library.resolve(entry)
        try await openVault(at: url)
        remember(in: library)
    }

    /// Creates a vault in `parent` and opens it: unlocked when a key was
    /// generated, locked (asking for the key) when only a recipient was given.
    func createVault(_ request: NewVaultRequest, in parent: URL, library: VaultLibrary) async throws -> CreatedVault {
        let created = try await library.create(request, in: parent)
        // The scope on `parent` ended; reopen through the bookmark `create` saved.
        if let entry = library.recents.first(where: { $0.name == VaultLibrary.displayName(of: created.url) }),
           let url = try? library.resolve(entry) {
            try await openVault(at: url)
        } else {
            try await openVault(at: created.url)
        }
        if let secret = created.secretKey {
            try await unlock(identityText: secret)
        }
        remember(in: library)
        return created
    }

    private func remember(in library: VaultLibrary) {
        guard let url = vaultURL else { return }
        do { try library.remember(url) } catch {
            errorMessage = "The vault opened, but InkVault could not save access to it for next time: \(error)"
        }
    }

    // MARK: - Edits

    /// Creates a note with one empty page and selects it.
    @discardableResult
    func createNote(title: String, paper: Paper, notebook: String?) async throws -> UUID {
        let id = UUID()
        let notebook = NoteOps.normalizedNotebook(notebook)
        try await commit([(id: id, ops: NoteOps.newNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        paper: paper, notebook: notebook))])
        switch sidebarSelection ?? .allNotes {
        case .notebook(let n) where n != notebook: sidebarSelection = .allNotes
        case .tag, .deleted: sidebarSelection = .allNotes
        default: break
        }
        selectedNoteID = id
        return id
    }

    /// Sets the notebook of every note (deleted ones too) in `old` to `new`;
    /// an empty `new` takes them out of any notebook.
    func renameNotebook(_ old: String, to new: String) async throws {
        let target = NoteOps.normalizedNotebook(new)
        guard target != old else { return }
        let ids = notes.filter { $0.notebook == old }.map(\.id)
        try await commit(ids.map { (id: $0, ops: [Op.setMeta(.notebook(target))]) })
        if sidebarSelection == .notebook(old) {
            sidebarSelection = target.map(SidebarItem.notebook) ?? .allNotes
        }
    }

    func moveNote(_ id: UUID, toNotebook notebook: String?) async throws {
        let target = NoteOps.normalizedNotebook(notebook)
        guard try summary(id).notebook != target else { return }
        try await commit([(id: id, ops: [.setMeta(.notebook(target))])])
    }

    func addTag(_ tag: String, to id: UUID) async throws {
        let tags = NoteOps.normalizedTags(try summary(id).tags + [tag])
        guard tags != (try summary(id).tags) else { return }
        try await commit([(id: id, ops: [.setMeta(.tags(tags))])])
    }

    func removeTag(_ tag: String, from id: UUID) async throws {
        let current = try summary(id).tags
        let tags = current.filter { $0 != tag }
        guard tags != current else { return }
        try await commit([(id: id, ops: [.setMeta(.tags(tags))])])
        if sidebarSelection == .tag(tag), !self.tags.contains(tag) { sidebarSelection = .allNotes }
    }

    func deleteNote(_ id: UUID) async throws {
        guard !(try summary(id).deleted) else { return }
        try await commit([(id: id, ops: [.deleteNote])])
    }

    func restoreNote(_ id: UUID) async throws {
        guard try summary(id).deleted else { return }
        try await commit([(id: id, ops: [.restoreNote])])
    }

    private func summary(_ id: UUID) throws -> NoteSummary {
        guard let note = notes.first(where: { $0.id == id }) else { throw ModelError.noteNotFound }
        return note
    }

    /// Writes one delta per entry, one after another, then refreshes just
    /// those summaries. Edits are serialised so two taps cannot interleave.
    private func commit(_ edits: [(id: UUID, ops: [Op])]) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        while isEditing { await Task.yield() }
        isEditing = true
        defer { isEditing = false }
        let stateURL = deviceStateURL
        let batch = edits
        let app = Self.appName
        do {
            try await Self.offMain {
                for edit in batch { try vault.apply(edit.ops, to: edit.id, deviceState: stateURL, app: app) }
            }
        } catch {
            try? await refresh(batch.map(\.id))   // some deltas may have landed
            throw error
        }
        try await refresh(batch.map(\.id))
    }

    /// Re-reads the summaries of `ids` and merges them into `notes`.
    func refresh(_ ids: [UUID]) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        let fresh = try await Self.offMain { try ids.map { try vault.summary(of: $0) } }
        guard self.vault?.url == vault.url else { return }
        var list = notes.filter { old in !fresh.contains { $0.id == old.id } }
        list += fresh
        notes = list.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }
}
