import Age
import Foundation
import Sempere
import Observation

/// How the note list is ordered.
enum NoteSort: String, CaseIterable, Identifiable, Sendable {
    case modified = "Date Modified"
    case title = "Title"

    var id: String { rawValue }
}

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
        /// Unlocked, but the vault still lists a classic X25519 key (or a key
        /// change was interrupted): only the migration screen is shown and no
        /// note is read until it finishes (`AppModel+Migration`, format.md §3.3.2).
        case migrating
    }

    /// Errors the shell reports to the user.
    enum ModelError: Error, Equatable, CustomStringConvertible {
        case noVaultOpen
        case notAnIdentity
        case noStoredKeys
        case passphraseMatchesNoKey
        case noteNotFound
        /// An iCloud note whose folder kept changing, or was never listed,
        /// while it was being downloaded.
        case noteNotDownloaded
        /// An edit over many notes while some are still downloading from iCloud.
        case notesStillDownloading

        var description: String {
            switch self {
            case .noVaultOpen: return "No vault is open."
            case .notAnIdentity: return "That text holds no AGE-SECRET-KEY-PQ-1… or AGE-SECRET-KEY-1… identity."
            case .noStoredKeys: return "This vault has no passphrase-protected key file."
            case .passphraseMatchesNoKey: return "The passphrase opens none of this vault's key files."
            case .noteNotFound: return "That note is no longer in the vault."
            case .noteNotDownloaded:
                return "iCloud Drive has not delivered all of this note's files yet. Try again in a moment."
            case .notesStillDownloading:
                return "Some notes are still downloading from iCloud Drive. Try again once the list has finished loading."
            }
        }
    }

    private(set) var phase: Phase = .noVault
    /// The open vault's folder.
    private(set) var vaultURL: URL?
    /// Every note in the vault, deleted ones included, sorted by title.
    var notes: [NoteSummary] = []
    /// True while vault I/O is in flight.
    private(set) var isBusy = false
    /// The last error, as a sentence for an alert; cleared by the view.
    var errorMessage: String?

    var sidebarSelection: SidebarItem? = .allNotes
    var selectedNoteID: UUID?
    /// True while the note list ticks several notes (to export them); the
    /// open note (`selectedNoteID`) is untouched meanwhile.
    var isSelectingNotes = false
    /// The ticked notes while `isSelectingNotes`.
    var multiSelection: Set<UUID> = []
    /// The export sheet's request (`AppModel+Export`).
    var exportRequest: ExportRequest?
    /// Filters the note list by title (recognised-text search is task 3f).
    var searchText = ""
    var sortOrder = NoteSort.modified
    /// True while an edit is being written.
    var isEditing = false
    /// Serialises edits (`commit`).
    let editGate = EditGate()
    /// Set while vault files are being fetched from iCloud Drive (`AppModel+Cloud`).
    var cloudProgress: CloudProgress?
    /// True when the open vault is in iCloud Drive: reads and writes are
    /// coordinated and reloads fetch new files first.
    var isCloudVault = false
    var cloudTask: Task<Bool, any Error>?
    /// Notes of an iCloud vault whose files are still downloading.
    var pendingNoteIDs: Set<UUID> = []
    /// The pending notes that have no summary yet (listed as placeholders).
    var placeholderNoteIDs: Set<UUID> = []
    /// The pending notes as of the last pass that read summaries (re-read once ready).
    var loadedPendingIDs: Set<UUID> = []
    /// Progress of the open iCloud vault's sync, for the list's progress bar;
    /// nil outside iCloud Drive.
    var cloudSync: CloudSyncStatus?
    /// The note `downloadNote` is fetching, with its files' progress.
    var noteDownload: (id: UUID, progress: CloudProgress)?
    var cloudSyncTask: Task<Void, Never>?
    /// The iCloud calls; tests replace them (`CloudVault.Hooks`).
    var cloudHooks = CloudVault.Hooks.live
    /// Pause between progressive passes, passes with an unchanged note set
    /// before the loop slows to `cloudIdleInterval` (doubling while nothing
    /// changes, up to `cloudMaxIdleInterval`), and how long without progress
    /// is a stall.
    var cloudPollInterval = Duration.seconds(1)
    var cloudSettlePasses = 3
    var cloudIdleInterval = Duration.seconds(15)
    var cloudMaxIdleInterval = Duration.seconds(60)
    var cloudStallTimeout = Duration.seconds(90)
    /// How many pending notes have downloads requested at once (`ProgressiveLoad`).
    var cloudWindow = ProgressiveLoad.defaultWindow


    /// Where this install keeps its device id and hybrid clock.
    let deviceStateURL: URL
    /// Why the selected note could not be opened (`showSelectedNote`).
    var editorFailure: (id: UUID, message: String)?
    /// The note open on the canvas, if any (`openEditor(for:)`).
    private(set) var editor: NoteEditor?

    private(set) var vault: Vault?
    /// The migration of a legacy vault while `phase == .migrating`.
    var migration: VaultMigration?
    /// The identities the vault was unlocked with, for reopening it after a
    /// migration that kept its key (`AppModel+Migration`).
    var unlockIdentities: [any AgeIdentity] = []
    private var scopedURL: URL?
    /// Bumped by `close()` (and so by every `openVault`): async work started
    /// under an older generation must not publish its result (the vault it
    /// read is gone).
    private(set) var generation = 0
    /// The save of the editor `close()` dropped; awaited before any note is
    /// opened again, so a reopened note is read after its last delta landed.
    private var closingEditor: Task<Void, Never>?
    /// This installation's device id and clock, created on first write
    /// access. Every write (canvas autosave and browser edits) ticks this one
    /// clock, so the state file has a single writer.
    private var deviceClock: DeviceClock?
    private let editorDebounce: Duration
    /// Test seam: awaited after each piece of off-main vault work.
    private let afterIO: (@Sendable () async -> Void)?

    init(deviceStateURL: URL = DeviceClock.defaultURL, editorDebounce: Duration = NoteEditor.defaultDebounce,
         afterIO: (@Sendable () async -> Void)? = nil) {
        self.deviceStateURL = deviceStateURL
        self.editorDebounce = editorDebounce
        self.afterIO = afterIO
    }

    // MARK: - Derived

    /// The vault's display name (folder name without `.sempere`).
    var vaultName: String? {
        vaultURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The notebook hierarchy of live notes (names are `/`-separated paths,
    /// format.md §5.4).
    var notebookTree: [NotebookNode] {
        NotebookNode.tree(notes.filter { !$0.deleted }.map(\.notebook))
    }

    /// Every notebook path in use by live notes, parents included, in tree order.
    var notebooks: [String] {
        NotebookNode.flatten(notebookTree)
    }

    /// Tags in use by live notes, sorted. Tags match case-insensitively
    /// ("Math" and "math" are one); the spelling shown is the first seen.
    var tags: [String] {
        var byKey: [String: String] = [:]
        for tag in notes.filter({ !$0.deleted }).flatMap(\.tags) where byKey[NoteOps.tagKey(tag)] == nil {
            byKey[NoteOps.tagKey(tag)] = tag
        }
        return byKey.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The note list for the current sidebar selection, title search and sort order.
    var visibleNotes: [NoteSummary] {
        let inSelection: [NoteSummary]
        switch sidebarSelection ?? .allNotes {
        case .allNotes: inSelection = notes.filter { !$0.deleted }
        case .notebook(let n): inSelection = notes.filter { !$0.deleted && NotebookPath.name($0.notebook, isWithin: n) }
        case .tag(let t): inSelection = notes.filter { !$0.deleted && $0.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } }
        case .deleted: inSelection = notes.filter(\.deleted)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? inSelection : inSelection.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Self.sorted(matching, by: sortOrder)
    }

    static func sorted(_ list: [NoteSummary], by order: NoteSort) -> [NoteSummary] {
        switch order {
        case .title:
            return list.sorted {
                let c = $0.title.localizedStandardCompare($1.title)
                return c == .orderedSame ? $0.id.uuidString < $1.id.uuidString : c == .orderedAscending
            }
        case .modified:
            return list.sorted {
                switch ($0.modified, $1.modified) {
                case let (a?, b?) where a != b: return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.id.uuidString < $1.id.uuidString
                }
            }
        }
    }

    var selectedNote: NoteSummary? {
        selectedNoteID.flatMap { id in notes.first { $0.id == id } }
    }

    // MARK: - Opening and unlocking

    /// Opens the vault at `url` by name only (no key yet). Starts
    /// security-scoped access for URLs from the document picker and keeps
    /// it until the vault is closed. A vault in iCloud Drive is downloaded
    /// first (`fetchFromICloud`).
    ///
    /// - Parameter scope: the URL whose security scope covers `url` when it is
    ///   not `url` itself (the folder the user picked, when `url` was found
    ///   inside it). Held instead of `url`'s own.
    func openVault(at url: URL, accessing scope: URL? = nil) async throws {
        close()
        let gen = generation
        let holder = scope ?? url
        let scoped = holder.startAccessingSecurityScopedResource()
        do {
            let cloud = try await fetchFromICloud(url, scope: .essentials)
            try ensureCurrent(gen)
            let opened = try await offMain { try CloudVault.coordinatedRead(cloud ? url : nil) { try Vault.open(at: url) } }
            try ensureCurrent(gen)
            if scoped { scopedURL = holder }
            isCloudVault = cloud
            vault = opened
            vaultURL = url
            phase = .locked
            // The notes start downloading while the user enters the key.
            startCloudSync()
        } catch {
            if scoped { holder.stopAccessingSecurityScopedResource() }
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
        let gen = generation
        let coordinate = coordinationURL
        let opened = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { try Vault.open(at: url, identities: identities) }
        }
        try ensureCurrent(gen)
        vault = opened
        unlockIdentities = identities
        if opened.isLegacy || opened.pendingRewrap {
            // Migrate-only (format.md §3.3.2): no note is listed or read.
            beginMigration(identities: identities)
            return
        }
        phase = .unlocked
        try await reload()
    }

    /// Enters the migration screen for the vault just unlocked with
    /// `identities`. The target key is a post-quantum identity among them
    /// that the vault already lists (a migration interrupted after its key
    /// was added), else a freshly generated one.
    func beginMigration(identities: [any AgeIdentity]) {
        guard let vault else { return }
        let classic = vault.classicRecipients
        let listed = Set(vault.recipients.map(\.key))
        let held = identities.compactMap { $0 as? NativeIdentity }
            .first { $0.isPostQuantum && listed.contains($0.recipient.string) }
        var migration = VaultMigration(classicRecipients: classic, key: held, keyIsNew: false)
        if held == nil && !classic.isEmpty {
            do {
                migration.key = try NativeIdentity.generate(.postQuantum)
                migration.keyIsNew = true
            } catch {
                migration.step = .failed("\(error)")
            }
        }
        self.migration = migration
        phase = .migrating
    }

    /// The vault as a migration step left it (`AppModel+Migration`).
    func replaceMigratingVault(_ next: Vault) {
        guard phase == .migrating else { return }
        vault = next
    }

    /// Makes `opened` the open vault and shows the notes (after a migration).
    func finishUnlock(_ opened: Vault, identities: [any AgeIdentity]) async throws {
        vault = opened
        unlockIdentities = identities
        migration = nil
        phase = .unlocked
        try await reload()
    }

    /// Unlocks with the text of an identity file (or a bare
    /// `AGE-SECRET-KEY-PQ-1…` or `AGE-SECRET-KEY-1…` line). Returns the identity (`RememberedKeys`).
    @discardableResult
    func unlock(identityText: String) async throws -> NativeIdentity {
        let identity: NativeIdentity
        do { identity = try IdentityFile.parse(identityText) } catch { throw ModelError.notAnIdentity }
        try await unlock(with: [identity])
        return identity
    }

    /// Unlocks with the passphrase of the vault's stored key files
    /// (`keys/<key-name>.key.age`, format.md §3.2). Every stored key the
    /// passphrase opens is used: during a migration the vault lists the
    /// classic and the post-quantum key, and finishing it may need both.
    /// Returns the first (post-quantum first) for `RememberedKeys`.
    @discardableResult
    func unlock(passphrase: String) async throws -> NativeIdentity {
        guard let locked = vault else { throw ModelError.noVaultOpen }
        let gen = generation
        let coordinate = coordinationURL
        let identities: [NativeIdentity] = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { () throws -> [NativeIdentity] in
                let stored = try locked.identityFiles()
                guard !stored.isEmpty else { throw ModelError.noStoredKeys }
                var opened: [NativeIdentity] = []
                for recipient in stored {
                    do { opened.append(try locked.readIdentityFile(recipient: recipient, passphrase: passphrase)) } catch VaultError.wrongPassphrase {
                        continue
                    }
                }
                guard !opened.isEmpty else { throw ModelError.passphraseMatchesNoKey }
                // Post-quantum keys first: they are the ones the vault keeps.
                return opened.filter(\.isPostQuantum) + opened.filter { !$0.isPostQuantum }
            }
        }
        try ensureCurrent(gen)
        guard let first = identities.first else { throw ModelError.passphraseMatchesNoKey }
        try await unlock(with: identities)
        return first
    }

    /// Re-reads every note summary from disk. In iCloud Drive, notes whose files
    /// are not downloaded yet are listed as placeholders and fill in as they
    /// arrive (`startCloudSync`), instead of the call waiting for all of them.
    func reload() async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        guard phase != .migrating else { return }   // nothing is read before the migration
        let gen = generation
        isBusy = true
        defer { if gen == generation { isBusy = false } }
        if isCloudVault {
            // Unlocking files first (small), then the notes as they arrive.
            _ = try await fetchFromICloud(vault.url)
            try ensureCurrent(gen)
            try await loadNotes(full: true)
            startCloudSync()
            return
        }
        let coordinate = coordinationURL
        let loaded = try await offMain { try CloudVault.coordinatedRead(coordinate) { try vault.summaries() } }
        try ensureCurrent(gen)
        notes = loaded
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
    }

    // MARK: - Editor

    /// Opens `noteID` on the canvas (nil closes it). The previous note is
    /// saved first. Needs an unlocked vault; the device clock is created on
    /// first use. In iCloud Drive the note is read, and its deltas written,
    /// under file coordination.
    func openEditor(for noteID: UUID?) async throws {
        guard editor?.noteID != noteID || noteID == nil else { return }
        let gen = generation
        let previous = editor
        editor = nil
        await previous?.close()
        await closingEditor?.value
        try ensureCurrent(gen)
        guard let noteID else { return }
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try await downloadNote(noteID)   // iCloud: this note first, before the rest of the vault
        let clock = try deviceClockForWriting()
        var verify: (@Sendable () throws -> Void)?
        if isCloudVault, let url = vaultURL {
            let hooks = cloudHooks
            verify = { try CloudVault.requireLocal(note: noteID, vault: url, hooks: hooks) }
        }
        let opened: NoteEditor
        do {
            opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               coordinated: isCloudVault, verify: verify)
        } catch CloudVault.CloudError.noteNotLocal {
            // A file went missing (or a new one was listed) since `downloadNote`: once more.
            try ensureCurrent(gen)
            try await downloadNote(noteID)
            opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               coordinated: isCloudVault, verify: verify)
        }
        await afterIO?()
        try ensureCurrent(gen)
        guard selectedNoteID == noteID else { return }   // the selection moved on meanwhile
        guard editor?.noteID != noteID else { return }    // a concurrent open won; keep its edits
        let stale = editor
        editor = opened
        if let stale { Task { await stale.close() } }
    }

    /// Opens the selected note on the canvas for the detail pane, keeping a
    /// failure next to the note (`editorFailure`) instead of a blank canvas.
    func showSelectedNote() async {
        let id = phase == .unlocked ? selectedNoteID : nil
        editorFailure = nil
        do {
            try await openEditor(for: id)
        } catch is CancellationError {
        } catch {
            if let id, selectedNoteID == id { editorFailure = (id, "\(error)") }
        }
    }

    /// Reloads the open editor when it shows `id` (after a browser edit that
    /// changes whether it may be edited, e.g. delete or restore). Pending
    /// canvas changes are saved first.
    func reopenEditor(ifShowing id: UUID) async throws {
        guard editor?.noteID == id else { return }
        try await openEditor(for: nil)
        try await openEditor(for: id)
    }

    func deviceClockForWriting() throws -> DeviceClock {
        if let deviceClock { return deviceClock }
        let clock = try DeviceClock(url: deviceStateURL)
        deviceClock = clock
        return clock
    }

    // MARK: - Closing

    /// Forgets the vault (and its keys). Folder access ends once the open
    /// note's pending changes and any edit already being written are saved.
    func close() {
        generation += 1
        cancelCloudDownload()
        stopCloudSync()
        isCloudVault = false
        isBusy = false
        let editor = self.editor
        let scoped = scopedURL
        self.editor = nil
        if editor != nil || scoped != nil {
            let earlier = closingEditor
            let gate = editGate
            closingEditor = Task {
                await earlier?.value
                await editor?.close()
                // A browser edit already writing (`commit`) finishes first.
                await gate.acquire()
                gate.release()
                scoped?.stopAccessingSecurityScopedResource()
            }
        }
        scopedURL = nil
        vault = nil
        migration = nil
        unlockIdentities = []
        vaultURL = nil
        notes = []
        selectedNoteID = nil
        isSelectingNotes = false
        multiSelection = []
        exportRequest = nil
        editorFailure = nil
        searchText = ""
        sidebarSelection = .allNotes
        phase = .noVault
    }

    /// Runs `body` and records its error for the UI instead of throwing.
    func report(_ body: () async throws -> Void) async {
        do { try await body() } catch is CancellationError {} catch { errorMessage = "\(error)" }
    }

    /// Throws `CancellationError` when `close()` or another `openVault` ran
    /// since `gen` was taken, so a late result cannot resurrect a closed vault.
    func ensureCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
    }

    /// Runs blocking vault work (file I/O, decryption) on a background thread.
    func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let value = try await Task.detached(priority: .userInitiated) { try work() }.value
        await afterIO?()
        return value
    }
}
