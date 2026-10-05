import Age
import Foundation
import InkVault

/// Vault browsing: opening and creating vaults, and the sidebar's edits.
/// Every edit is one delta per note, written through `NoteWriter` with the
/// same device clock as the canvas; the app never writes vault files itself.
extension AppModel {

    // MARK: - Opening and creating

    /// Opens what the user picked (a `.inkvault` vault, a plain folder, a folder
    /// holding one vault, or a file inside a vault: `VaultLocator`) and
    /// remembers it.
    func open(picked url: URL, library: VaultLibrary) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let vaultURL = try VaultLocator.resolve(url)
        try await openVault(at: vaultURL, accessing: vaultURL == url ? nil : url)
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
    ///
    /// When another vault is opened or this one closed meanwhile, the vault
    /// is still created and returned (with its key, which nothing else holds)
    /// but not opened.
    func createVault(_ request: NewVaultRequest, in parent: URL, library: VaultLibrary) async throws -> CreatedVault {
        let gen = generation
        let created = try await library.create(request, in: parent)
        guard gen == generation else { return created }
        do {
            // The scope on `parent` ended; reopen through the bookmark `create` saved
            // (by id: another recent vault may have the same name).
            if let entry = library.recents.first(where: { $0.id == created.recentID }),
               let url = try? library.resolve(entry) {
                try await openVault(at: url)
            } else {
                try await openVault(at: created.url)
            }
            let opened = generation
            if let secret = created.secretKey {
                try ensureCurrent(opened)
                try await unlock(identityText: secret)
            }
            try ensureCurrent(opened)
        } catch is CancellationError {
            return created
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
        let notebook = NotebookPath.canonical(notebook)
        try await commit([(id: id, ops: NoteOps.newNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        paper: paper, notebook: notebook))])
        switch sidebarSelection ?? .allNotes {
        case .notebook(let n) where !NotebookPath.name(notebook, isWithin: n): sidebarSelection = .allNotes
        case .tag, .deleted: sidebarSelection = .allNotes
        default: break
        }
        selectedNoteID = id
        return id
    }

    /// Renames or moves the notebook `old` (a `/`-separated path, format.md
    /// §5.4) to `new`: every note in it or below it, deleted ones too, gets
    /// the `old` prefix of its notebook replaced by `new` (one `setMeta` per
    /// note). An empty `new` takes the notes directly in `old` out of any
    /// notebook and lifts its sub-notebooks to the top level.
    func renameNotebook(_ old: String, to new: String) async throws {
        guard let old = NotebookPath.canonical(old) else { return }
        let target = NotebookPath.canonical(new)
        guard target != old else { return }
        let edits: [(id: UUID, ops: [Op])] = notes.compactMap { note in
            guard NotebookPath.name(note.notebook, isWithin: old) else { return nil }
            let renamed = NotebookPath.renamed(note.notebook, from: old, to: target)
            return renamed == note.notebook ? nil : (id: note.id, ops: [Op.setMeta(.notebook(renamed))])
        }
        try await commit(edits)
        if case .notebook(let selected)? = sidebarSelection, NotebookPath.name(selected, isWithin: old) {
            sidebarSelection = NotebookPath.renamed(selected, from: old, to: target).map(SidebarItem.notebook) ?? .allNotes
        }
    }

    /// Puts a note into the notebook path `notebook` (nil or blank: none).
    func moveNote(_ id: UUID, toNotebook notebook: String?) async throws {
        let target = NotebookPath.canonical(notebook)
        guard try summary(id).notebook != target else { return }
        try await commit([(id: id, ops: [.setMeta(.notebook(target))])])
    }

    /// Renames a note (one `setMeta(.title)` delta). Titles are labels, not keys:
    /// any title, including one another note has, is fine.
    func renameNote(_ id: UUID, to title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try summary(id).title != title else { return }
        try await commit([(id: id, ops: [.setMeta(.title(title))])])
    }

    /// Adds a tag. Matching ignores case: a tag the note has already (in any
    /// case) is not added again, and the spelling of a tag already used in the
    /// vault wins over the typed one.
    func addTag(_ tag: String, to id: UUID) async throws {
        let typed = NoteOps.normalizedTag(tag)
        guard !typed.isEmpty else { return }
        let current = try summary(id).tags
        guard !current.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(typed) }) else { return }
        let spelling = tags.first { NoteOps.tagKey($0) == NoteOps.tagKey(typed) } ?? typed
        try await commit([(id: id, ops: [.setMeta(.tags(NoteOps.normalizedTags(current + [spelling])))])])
    }

    func removeTag(_ tag: String, from id: UUID) async throws {
        let current = try summary(id).tags
        let tags = current.filter { NoteOps.tagKey($0) != NoteOps.tagKey(tag) }
        guard tags != current else { return }
        try await commit([(id: id, ops: [.setMeta(.tags(tags))])])
        if case .tag(let selected)? = sidebarSelection, !self.tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(selected) }) {
            sidebarSelection = .allNotes
        }
    }

    /// Moves a note to Recently Deleted; open on the canvas, it reopens read-only.
    func deleteNote(_ id: UUID) async throws {
        guard !(try summary(id).deleted) else { return }
        try await commit([(id: id, ops: [.deleteNote])])
        try await reopenEditor(ifShowing: id)
    }

    /// Restores a note; open on the canvas, it reopens editable.
    func restoreNote(_ id: UUID) async throws {
        guard try summary(id).deleted else { return }
        try await commit([(id: id, ops: [.restoreNote])])
        try await reopenEditor(ifShowing: id)
    }

    private func summary(_ id: UUID) throws -> NoteSummary {
        guard let note = notes.first(where: { $0.id == id }) else { throw ModelError.noteNotFound }
        return note
    }

    /// Writes one delta per entry, one after another, then refreshes just
    /// those summaries. Edits are serialised (`editGate`) so two taps cannot
    /// interleave; the vault is looked up after waiting, so an edit queued
    /// before the vault closed is not written into it afterwards (and
    /// `close()` waits for one being written before access to the folder
    /// ends). Deltas go through `NoteWriter.append` with the canvas's device
    /// clock; in iCloud Drive each is a coordinated write on its note's folder.
    private func commit(_ edits: [(id: UUID, ops: [Op])]) async throws {
        await editGate.acquire()
        defer { editGate.release() }
        guard let vault else { throw ModelError.noVaultOpen }
        guard vault.canRead else { throw vault.isLocked ? VaultError.locked : VaultError.noIdentities }
        let clock = try deviceClockForWriting()
        isEditing = true
        defer { isEditing = false }
        let batch = edits
        let cloud = isCloudVault
        do {
            for edit in batch {
                try await NoteWriter.append(edit.ops, to: edit.id, vault: vault, clock: clock, coordinated: cloud)
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
        let gen = generation
        let coordinate = coordinationURL
        let fresh = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { try ids.map { try vault.summary(of: $0) } }
        }
        try ensureCurrent(gen)
        var list = notes.filter { old in !fresh.contains { $0.id == old.id } }
        list += fresh
        notes = list.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }
}

/// A first-come first-served lock for the main actor: waiters sleep instead
/// of spinning.
@MainActor
final class EditGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are waiting in `acquire`.
    var waiting: Int { waiters.count }

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock to the next waiter, if any.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
