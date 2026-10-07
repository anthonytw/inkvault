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
    /// The notes the last "Recognize All Notes" run changed (`AppModel.recognitionResults`).
    case recentlyRecognized
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
        /// The open note's pending canvas changes could not be saved first.
        case unsavedChanges(String)
        /// A notebook dropped into itself or a notebook inside it.
        case invalidNotebookMove

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
                return "Some notes are still loading or downloading from iCloud Drive. Try again once the list has finished loading."
            case .invalidNotebookMove: return "A notebook cannot be moved into itself or into a notebook inside it."
            case .unsavedChanges(let reason):
                return "The note's latest changes could not be saved first, so nothing was restored. \(reason)"
            }
        }
    }

    private(set) var phase: Phase = .noVault
    /// The open vault's folder.
    private(set) var vaultURL: URL?
    /// Every note in the vault, deleted ones included, sorted by title
    /// (`byTitle`). Passes change it in batches (`queueListUpdate`).
    var notes: [NoteSummary] = [] {
        didSet {
            listVersion &+= 1
            updateSearch()
        }
    }
    /// Bumped on every change of `notes`; keys the derived lists (`derived`).
    private(set) var listVersion = 0
    /// `visibleNotes`, `tags` and `notebookTree`, computed once per change.
    @ObservationIgnored var derived = DerivedLists()
    /// True while vault I/O is in flight.
    private(set) var isBusy = false
    /// The last error, as a sentence for an alert; cleared by the view.
    var errorMessage: String?
    /// Reading note summaries (opening or refreshing the vault), for the
    /// list's "Opening vault: N of M"; nil when no read is running.
    var loading: NoteLoading?
    /// True once a listing of the open vault has completed (the list is
    /// then what the vault holds, not a partial or cached view).
    var listLoaded = false
    /// Why the last listing failed, shown in an empty list (cleared by the next one).
    var loadFailure: String?
    /// Notes whose summary in `notes` was read (or confirmed from the cache)
    /// in this session. A summary shown from an earlier launch's cache, or a
    /// placeholder, is not: edits that decide from a summary re-read the
    /// note first, and a notebook rename waits until every note is verified.
    var verifiedNoteIDs: Set<UUID> = []
    /// Bumped per note by `refresh` (an edit's own re-read): a listing batch
    /// read before it must not merge its older summary over the newer one.
    var summaryEpochs: [UUID: Int] = [:]
    /// The newest summary-cache save (`saveSummaryCache`).
    @ObservationIgnored var summaryCacheSave: Task<Void, Never>?

    var sidebarSelection: SidebarItem? = .allNotes { didSet { updateSearch() } }
    var selectedNoteID: UUID?
    /// The search field's text. `visibleNotes` filters by title with it; the
    /// note list shows `searchResults` (`AppModel+Search`) while it is not empty.
    var searchText = "" { didSet { updateSearch() } }
    var searchScope = SearchScope.everywhere { didSet { updateSearch() } }
    /// Notes matching `searchText` (title, notebook, tag, recognised handwriting), best first.
    var searchResults: [NoteSearchHit] = []
    /// True from a change of the query until its results are in.
    var isSearching = false
    /// The page to show once the note is open (a tapped search hit).
    var pendingJump: PageJump?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Pause after typing before the search runs.
    @ObservationIgnored var searchDebounce = Duration.milliseconds(200)
    /// Reads handwriting on pages as they change and when notes open; nil = off.
    var recognizer: (any PageRecognizing)? {
        didSet {
            editor?.recognizer = recognizer
            for window in windowEditors.values { window.recognizer = recognizer }
        }
    }
    /// Progress of "Recognise All Notes" (`AppModel+Search`).
    var recognitionProgress: RecognitionProgress?
    /// What the last "Recognize All Notes" run changed, kept (also after it
    /// ends) until the next run starts; the "Recently Recognized" filter lists it.
    var recognitionResults: RecognitionResults?
    /// What is being dragged inside the app (set when a drag starts), so the
    /// sidebar can tell whether a row would accept it while the drag is still over it.
    var draggedPayload: DragPayload?
    /// The item provider of the drag in progress, kept until it is dropped or
    /// another drag starts: iPadOS 26 releases a provider as soon as `onDrag`
    /// returns it unless someone holds it (`beginDrag`).
    @ObservationIgnored var dragProvider: NSItemProvider?
    /// The sidebar row a drag is over that would accept it (highlighted).
    var dropTarget: DropTarget?
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    /// Pause after the last stroke change before the open note's pages are recognised.
    let recognitionDelay: Duration
    /// True while the note list ticks several notes (to export them); the
    /// open note (`selectedNoteID`) is untouched meanwhile.
    var isSelectingNotes = false
    /// The ticked notes while `isSelectingNotes`.
    var multiSelection: Set<UUID> = []
    /// The export sheet's request (`AppModel+Export`).
    var exportRequest: ExportRequest?
    var sortOrder = NoteSort.modified
    /// True while an edit is being written.
    var isEditing = false
    /// Serialises edits (`commit`).
    let editGate = EditGate()
    /// Thin old autosaves once a day after a vault's notes are listed
    /// (`thinIfDue`, format.md §5.8.4). The app turns it on; tests leave it
    /// off so nothing is written that they did not ask for.
    var automaticThinning = false
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
    /// Per note shown, the sorted revision file names its summary was made
    /// from: from the index on open, then from every read. A pass reads only
    /// notes whose names on disk differ (`reconcile`).
    @ObservationIgnored var indexedNames: [UUID: [String]] = [:]
    /// Summary changes waiting for the next list update (`queueListUpdate`).
    @ObservationIgnored var listUpserts: [UUID: NoteSummary] = [:]
    @ObservationIgnored var listRemovals: Set<UUID> = []
    @ObservationIgnored var listFlushTask: Task<Void, Never>?
    @ObservationIgnored var lastListApply: ContinuousClock.Instant?
    /// The shortest time between two list updates while notes are read.
    var listUpdateInterval = Duration.milliseconds(250)
    /// Note folders a file presenter reported changed, for the next pass;
    /// `dirtyAll` when it could not say which.
    @ObservationIgnored var dirtyNoteIDs: Set<UUID> = []
    @ObservationIgnored var dirtyAll = false
    /// Wakes the sync loop early when a change is reported (`noteFoldersChanged`).
    @ObservationIgnored let syncWakeup = SyncWakeup()
    /// Reports changes inside the open iCloud vault's `notes/` folder.
    @ObservationIgnored var notesPresenter: NotesFolderPresenter?
    /// The background validation in progress (`validateIfDue`).
    @ObservationIgnored var validationTask: Task<Void, Never>?
    @ObservationIgnored var validationRun = 0
    /// When the background validation (`validateVault`) last finished.
    @ObservationIgnored var lastValidation: ContinuousClock.Instant?
    /// How often the background validation runs while the vault is open
    /// (also once, shortly after the list settles).
    var cloudValidationInterval = Duration.seconds(30 * 60)
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
    /// Test seam: awaited before an editor opened from the drawing cache
    /// takes the note it read in the background.
    @ObservationIgnored var editorLoadHook: (@Sendable () async -> Void)?
    /// Test seam: told how many notes each listing batch read.
    @ObservationIgnored var onSummaryRead: (@Sendable (Int) -> Void)?
    /// Notes read per published batch, and threads reading them (`AppModel+Loading`).
    var loadBatchSize = 24
    var loadConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    /// Where summaries are cached between launches (`SummaryCache`); nil (the
    /// default, for tests): no cache. The app passes `defaultSummaryCacheDirectory`.
    let summaryCacheDirectory: URL?
    /// The open vault's summary cache, once unlocked.
    @ObservationIgnored var summaryCache: SummaryCache?
    /// The load of `summaryCache` in progress (`openSummaryCache`).
    @ObservationIgnored var summaryCacheOpening: Task<Void, any Error>?
    /// Where page drawings are cached between note opens (`DrawingCache`);
    /// nil (the default, for tests): no cache. The app passes
    /// `DrawingCache.defaultRoot`.
    let drawingCacheRoot: URL?
    /// The open vault's drawing cache, opened with the first note; deleted
    /// when the vault closes.
    @ObservationIgnored var drawingCache: DrawingCache?
    /// The listing started by `unlock`, owned by the model so that no view
    /// (an unlock sheet going away) can cancel it.
    @ObservationIgnored var loadTask: Task<Void, any Error>?
    /// Serialises listings: a reload, the iCloud sync loop and a pull to
    /// refresh never read the same notes at once.
    let loadGate = EditGate()


    /// Where this install keeps its device id and hybrid clock.
    let deviceStateURL: URL
    /// Why the selected note could not be opened (`showSelectedNote`).
    var editorFailure: (id: UUID, message: String)?
    /// The note open on the canvas, if any (`openEditor(for:)`).
    private(set) var editor: NoteEditor?

    private(set) var vault: Vault? {
        // Decrypted attachments and copied items belong to the vault (and the
        // secret) they came from.
        didSet { dropAttachments() }
    }
    /// Decrypted attachments of the open vault (`AppModel+Attachments`),
    /// created on first use, deleted whenever `vault` changes or closes.
    @ObservationIgnored var blobCache: BlobCache?
    /// Where this model's attachment caches go; tests pass their own.
    @ObservationIgnored var blobCacheFolder = BlobCache.folder
    /// Items copied for pasting (`ItemClipboard`), within the open vault.
    let itemClipboard = ItemClipboard()
    /// Editors of note windows (Mac), by note id: one per note, each with its
    /// own canvas (`AppModel+Windows`).
    var windowEditors: [UUID: NoteEditor] = [:]
    /// Notes shown by a window of their own; the library window's detail pane
    /// does not open an editor for them.
    var windowClaims: Set<UUID> = []
    /// Bumped when the vault's keys changed under the open editors
    /// (`AppModel+Keys`): views reopen their notes.
    var keyEpoch = 0
    /// True while a recipient change re-encrypts the vault (`AppModel+Keys`):
    /// no editor opens meanwhile, since it would hold the old vault and secret.
    var isChangingKeys = false
    /// The library window whose detail pane shows `editor` (`WindowUI.id`).
    /// One canvas per editor: a second canvas on the same editor would report
    /// a drawing without the first one's new strokes, which the ledger takes
    /// as erasures.
    var canvasWindow: UUID?
    /// When a note window last asked for a library window (coalesces the
    /// requests of several restored note windows).
    var libraryWindowRequested: Date?
    /// Where this model's PDF exports (drag to Finder) are written; emptied when the vault closes.
    let exportFolder = NotePDFExport.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    /// Library windows on screen (a note window restored alone opens one).
    var libraryWindowCount = 0
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
    var closingEditor: Task<Void, Never>?
    /// This installation's device id and clock, created on first write
    /// access. Every write (canvas autosave and browser edits) ticks this one
    /// clock, so the state file has a single writer.
    private var deviceClock: DeviceClock?
    let editorDebounce: Duration
    /// Test seam: awaited after each piece of off-main vault work.
    private let afterIO: (@Sendable () async -> Void)?

    init(deviceStateURL: URL = DeviceClock.defaultURL, editorDebounce: Duration = NoteEditor.defaultDebounce,
         recognizer: (any PageRecognizing)? = nil, recognitionDelay: Duration = NoteEditor.defaultRecognitionDelay,
         summaryCacheDirectory: URL? = nil, drawingCacheRoot: URL? = nil,
         automaticThinning: Bool = false,
         afterIO: (@Sendable () async -> Void)? = nil) {
        self.deviceStateURL = deviceStateURL
        self.automaticThinning = automaticThinning
        self.summaryCacheDirectory = summaryCacheDirectory
        self.drawingCacheRoot = drawingCacheRoot
        self.editorDebounce = editorDebounce
        self.recognizer = recognizer
        self.recognitionDelay = recognitionDelay
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
        let version = listVersion
        if let t = derived.tree, t.version == version { return t.value }
        let tree = NotebookNode.tree(notes.filter { !$0.deleted }.map(\.notebook))
        derived.tree = (version, tree)
        return tree
    }

    /// Every notebook path in use by live notes, parents included, in tree order.
    var notebooks: [String] {
        NotebookNode.flatten(notebookTree)
    }

    /// Tags in use by live notes, sorted. Tags match case-insensitively
    /// ("Math" and "math" are one); the spelling shown is the first seen.
    var tags: [String] {
        let version = listVersion
        if let t = derived.tags, t.version == version { return t.value }
        let tags = NoteOps.vaultTags(notes)
        derived.tags = (version, tags)
        return tags
    }

    /// The note list for the current sidebar selection, title search and sort order.
    var visibleNotes: [NoteSummary] {
        let key = DerivedLists.VisibleKey(version: listVersion, selection: sidebarSelection, search: searchText,
                                          sort: sortOrder)
        if let v = derived.visible, v.key == key { return v.value }
        let value = computeVisibleNotes()
        derived.visible = (key, value)
        return value
    }

    private func computeVisibleNotes() -> [NoteSummary] {
        let inSelection = notesInSelection
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? inSelection : inSelection.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Self.sorted(matching, by: sortOrder)
    }

    /// The notes the sidebar selection shows, before any search.
    var notesInSelection: [NoteSummary] {
        switch sidebarSelection ?? .allNotes {
        case .allNotes: return notes.filter { !$0.deleted }
        case .notebook(let n): return notes.filter { !$0.deleted && NotebookPath.name($0.notebook, isWithin: n) }
        case .tag(let t): return notes.filter { !$0.deleted && $0.tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(t) } }
        case .deleted: return notes.filter(\.deleted)
        case .recentlyRecognized:
            let ids = Set(recognitionResults?.notes.map(\.id) ?? [])
            return notes.filter { !$0.deleted && ids.contains($0.id) }
        }
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
        let interval = Perf.begin(.vaultOpen)
        do {
            // A sandboxed Mac refuses a folder whose saved permission did not come back.
            #if DEBUG
            NSLog("SempereDebug folderAccess scoped=%d listable=%d", scoped ? 1 : 0,
                  (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? 1 : 0)
            #endif
            try FolderAccess.check(url, scoped: scoped)
            let cloud = try await fetchFromICloud(url, scope: .essentials)
            try ensureCurrent(gen)
            let opened = try await offMain { try CloudVault.coordinatedRead(cloud ? url : nil) { try Vault.open(at: url) } }
            try ensureCurrent(gen)
            Perf.end(interval, "cloud=\(cloud)")
            if scoped { scopedURL = holder }
            isCloudVault = cloud
            vault = opened
            vaultURL = url
            phase = .locked
            // The notes start downloading while the user enters the key.
            startCloudSync()
        } catch {
            Perf.end(interval, "failed")
            if scoped { holder.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Opens the vault at `url` and unlocks it with `identities` in one step.
    func openVault(at url: URL, identities: [any AgeIdentity]) async throws {
        try await openVault(at: url)
        try await unlock(with: identities)
    }

    /// Unlocks the open vault with age identities and starts listing its
    /// notes (`startLoadingNotes`): cached summaries at once, then the rest
    /// as they are read. The listing belongs to the model, so a caller that
    /// goes away (the unlock sheet) does not stop it.
    ///
    /// - Parameter awaitNotes: wait for the listing (and throw its error)
    ///   before returning. The UI passes false, so the unlock sheet closes as
    ///   soon as the key is accepted; failures then go to `errorMessage`.
    func unlock(with identities: [any AgeIdentity], awaitNotes: Bool = true) async throws {
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
        startLoadingNotes(reportErrors: !awaitNotes)
        if awaitNotes { try await notesLoaded() }
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

    /// The vault after a recipient change made through the library
    /// (`AppModel+Keys`); every editor was closed before it.
    func adoptRewrapped(_ next: Vault) {
        guard phase == .unlocked, next.vaultId == vault?.vaultId else { return }
        vault = next
        keyEpoch += 1
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
    func unlock(identityText: String, awaitNotes: Bool = true) async throws -> NativeIdentity {
        let identity: NativeIdentity
        do { identity = try IdentityFile.parse(identityText) } catch { throw ModelError.notAnIdentity }
        try await unlock(with: [identity], awaitNotes: awaitNotes)
        return identity
    }

    /// Unlocks with the passphrase of the vault's stored key files
    /// (`keys/<key-name>.key.age`, format.md §3.2). Every stored key the
    /// passphrase opens is used: during a migration the vault lists the
    /// classic and the post-quantum key, and finishing it may need both.
    /// Returns the first (post-quantum first) for `RememberedKeys`.
    @discardableResult
    func unlock(passphrase: String, awaitNotes: Bool = true) async throws -> NativeIdentity {
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
        try await unlock(with: identities, awaitNotes: awaitNotes)
        return first
    }

    /// Re-reads every note summary from disk: summaries whose revision files
    /// have not changed come from the `SummaryCache`, the rest are read in
    /// batches that are published as they finish (`loading` says how far it
    /// got). Before the first listing of a vault the cached summaries are
    /// shown at once. In iCloud Drive, notes whose files are not downloaded
    /// yet are listed as placeholders (or their cached summary) and fill in
    /// as they arrive (`startCloudSync`), instead of the call waiting for all
    /// of them.
    func reload() async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        guard phase != .migrating else { return }   // nothing is read before the migration
        let gen = generation
        isBusy = true
        defer { if gen == generation { isBusy = false } }
        do {
            try await openSummaryCache()
            try ensureCurrent(gen)
            if isCloudVault {
                // Unlocking files first (small), then the notes that changed.
                _ = try await fetchFromICloud(vault.url)
                try ensureCurrent(gen)
                try await reconcile(full: true)
                startCloudSync()
            } else {
                try await listLocalNotes()
            }
            if gen == generation { loadFailure = nil }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if gen == generation { loadFailure = "\(error)" }
            throw error
        }
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
        guard !isChangingKeys else { throw CancellationError() }   // reopened after the change (`keyEpoch`)
        let epoch = keyEpoch
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let interval = Perf.begin(.noteOpen)
        let render = Perf.begin(.noteFirstRender)
        var shown = false
        defer {
            if !shown {
                Perf.end(interval, "\(Perf.short(noteID)) not shown")
                Perf.end(render, "\(Perf.short(noteID)) not shown")
            }
        }
        // iCloud: this note first, before the rest of the vault.
        let download = Perf.begin(.noteDownload)
        do { try await downloadNote(noteID) } catch {
            Perf.end(download, "\(Perf.short(noteID)) failed")
            throw error
        }
        Perf.end(download, "\(Perf.short(noteID))")
        let clock = try deviceClockForWriting()
        let cache = await openDrawingCache()
        let url = vault.url
        // The names say which cached version of the note is current; listing them reads no file.
        let listed = cache == nil ? nil : try? await offMain {
            try VaultEnumeration.listNotes(vault: url, only: [noteID]).first?.names
        }
        var verify: (@Sendable () throws -> Void)?
        if isCloudVault, let url = vaultURL {
            let hooks = cloudHooks
            verify = { try CloudVault.requireLocal(note: noteID, vault: url, hooks: hooks) }
        }
        let opened: NoteEditor
        do {
            opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               coordinated: isCloudVault, verify: verify, cache: cache,
                                               listedNames: listed, beforeFinishing: editorLoadHook,
                                               redownload: { [weak self] in
                                                   guard let self else { throw CancellationError() }
                                                   try self.ensureCurrent(gen)   // never into another vault
                                                   try await self.downloadNote(noteID)
                                               })
        } catch CloudVault.CloudError.noteNotLocal {
            // A file went missing (or a new one was listed) since `downloadNote`: once more.
            try ensureCurrent(gen)
            try await downloadNote(noteID)
            opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               coordinated: isCloudVault, verify: verify, cache: cache)
        }
        await afterIO?()
        guard gen == generation, selectedNoteID == noteID,   // closed, or the selection moved on meanwhile
              editor?.noteID != noteID else {                // a concurrent open won; keep its edits
            opened.cancelLoading()
            try ensureCurrent(gen)
            return
        }
        // A note window took the note meanwhile (one editor per note), or the
        // keys changed under the vault copy this editor was opened with.
        guard !windowClaims.contains(noteID), !isChangingKeys, epoch == keyEpoch else {
            Task { await opened.close() }
            throw CancellationError()
        }
        // The background read of a note opened from the cache failed: show the
        // failure (and Try Again) rather than a partial read-only canvas.
        opened.onLoadFailed = { [weak self, weak opened] message in
            guard let self, let opened, self.editor === opened else { return }
            self.editor = nil
            if self.selectedNoteID == noteID { self.editorFailure = (noteID, message) }
            Task { await opened.close() }
        }
        if opened.loadFailed {   // it failed before the callback was set
            if let stale = editor { editor = nil; Task { await stale.close() } }
            editorFailure = (noteID, opened.readOnlyReason ?? "This note could not be read.")
            Task { await opened.close() }
            return
        }
        let stale = editor
        opened.prepareBlobWrite = blobWritePreparer(note: noteID)
        opened.onRecognized = { [weak self] id in
            guard let self else { return }
            Task { try? await self.refresh([id]) }   // search sees the new text
        }
        Perf.end(interval, "\(Perf.short(noteID)) pages=\(opened.pages.count) fromCache=\(opened.isPreparing)")
        opened.openInterval = render   // ended by the canvas when the ink is on screen
        shown = true
        editor = opened
        applyPendingJump()
        if let stale { Task { await stale.close() } }
    }

    /// Opens the open vault's drawing cache (`DrawingCache`) once.
    func openDrawingCache() async -> DrawingCache? {
        if let drawingCache { return drawingCache }
        guard let root = drawingCacheRoot, let vault, vault.canRead else { return nil }
        let gen = generation
        let cache = try? await offMain(priority: .utility) { try DrawingCache(root: root, vault: vault) }
        // A newer session may already use the same folder (the vault closed and
        // reopened meanwhile): drop this instance without deleting anything; the
        // closed session's `close` cleared its cache.
        guard gen == generation else { return nil }
        if drawingCache == nil { drawingCache = cache }
        return drawingCache
    }

    /// Opens the selected note on the canvas for the detail pane, keeping a
    /// failure next to the note (`editorFailure`) instead of a blank canvas.
    func showSelectedNote() async {
        var id = phase == .unlocked ? selectedNoteID : nil
        if let claimed = id, windowClaims.contains(claimed) { id = nil }   // a window of its own has it
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
        if windowEditors[id] != nil { await reopenWindowNote(id) }
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
        let windowed = Array(windowEditors.values)
        windowEditors = [:]
        windowClaims = []
        let scoped = scopedURL
        self.editor = nil
        NotePDFExport.purge(in: exportFolder, olderThan: 0)   // plaintext PDFs dragged out of this vault
        if editor != nil || scoped != nil || !windowed.isEmpty {
            let earlier = closingEditor
            let gate = editGate
            closingEditor = Task {
                await earlier?.value
                await editor?.close()
                for open in windowed { await open.close() }
                // A browser edit already writing (`commit`) finishes first.
                await gate.acquire()
                gate.release()
                scoped?.stopAccessingSecurityScopedResource()
            }
        }
        scopedURL = nil
        loadTask?.cancel()
        loadTask = nil
        loading = nil
        listLoaded = false
        loadFailure = nil
        verifiedNoteIDs = []
        summaryEpochs = [:]
        indexedNames = [:]
        discardListUpdates()
        dirtyNoteIDs = []
        dirtyAll = false
        lastValidation = nil
        summaryCache = nil
        summaryCacheOpening = nil
        // Drawings of this vault's notes do not outlive it on this device.
        drawingCache?.close()
        drawingCache = nil
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
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionProgress = nil
        recognitionResults = nil
        draggedPayload = nil
        dragProvider = nil
        dropTarget = nil
        pendingJump = nil
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
    func offMain<T: Sendable>(priority: TaskPriority = .userInitiated,
                              _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let value = try await Task.detached(priority: priority) { try work() }.value
        await afterIO?()
        return value
    }
}
