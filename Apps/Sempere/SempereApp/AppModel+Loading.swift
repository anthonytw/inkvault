import Foundation
import Sempere

/// How far a listing of the open vault has got, for "Opening vault: 120 of 640".
struct NoteLoading: Equatable, Sendable {
    /// Notes whose summary is in (from the cache or read).
    var done = 0
    /// Notes to summarise in this pass.
    var total = 0
    /// True when the list already shows every note (from the cache or a
    /// previous listing) and this pass only picks up changes.
    var refreshing = false

    var fractionCompleted: Double { total == 0 ? 1 : min(1, Double(done) / Double(total)) }

    /// "Opening vault: 120 of 640 notes", or "Updating notes: …" over a list already shown.
    var headline: String {
        let what = refreshing ? "Updating notes" : "Opening vault"
        return "\(what): \(done) of \(total) note\(total == 1 ? "" : "s")"
    }
}

/// Why the note list is empty; shown instead of a blank list
/// (`AppModel.emptyListReason`).
enum EmptyListReason: Equatable, Sendable {
    /// Notes are being read; nothing to show yet.
    case loading(NoteLoading?)
    /// Notes are still downloading from iCloud Drive.
    case downloading(CloudSyncStatus)
    /// The listing failed or iCloud stalled; the text says why.
    case failed(String)
    /// The search matches nothing among the notes shown.
    case noMatches(String)
    /// The sidebar selection (a notebook, a tag, Recently Deleted) has no notes.
    case emptySelection
    /// The vault holds no notes.
    case emptyVault
}

extension AppModel {
    /// Summary caches of every vault this install opened: one encrypted file
    /// per vault secret in Application Support (`format.md` §10). Not backed up.
    nonisolated static var defaultSummaryCacheDirectory: URL? {
        DeviceClock.defaultURL.deletingLastPathComponent().appendingPathComponent("SummaryCache")
    }

    /// Why the note list shows nothing, or nil when it shows something.
    var emptyListReason: EmptyListReason? {
        guard phase == .unlocked, visibleNotes.isEmpty else { return nil }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveNotes = notes.contains { !$0.deleted }
        if loading != nil || (!listLoaded && loadFailure == nil) {
            // A search over a list still filling in may match later.
            if !query.isEmpty && liveNotes { return .noMatches(query) }
            return .loading(loading)
        }
        if let sync = cloudSync, sync.isDownloading, !(liveNotes && !query.isEmpty) { return .downloading(sync) }
        if let failure = loadFailure { return .failed(failure) }
        if let problem = cloudSync?.problem, notes.isEmpty { return .failed(problem) }
        if !query.isEmpty { return .noMatches(query) }
        if notes.isEmpty { return .emptyVault }
        return .emptySelection
    }

    /// Lists the notes in a task the model owns. The previous listing, if
    /// any, finishes first (`loadGate`).
    ///
    /// - Parameter reportErrors: put a failure in `errorMessage` (nobody
    ///   awaits the task) rather than only rethrowing it from `notesLoaded`.
    func startLoadingNotes(reportErrors: Bool) {
        let gen = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.reload()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if reportErrors, self.generation == gen { self.errorMessage = "\(error)" }
                throw error
            }
        }
    }

    /// Waits for the listing `unlock` started.
    func notesLoaded() async throws {
        try await loadTask?.value
    }

    /// Opens the open vault's `SummaryCache` (decrypting its file) once.
    func openSummaryCache() async throws {
        guard summaryCache == nil, let dir = summaryCacheDirectory, let vault, vault.canRead else { return }
        let gen = generation
        let cache = try? await offMain { () throws -> SummaryCache in
            Self.prepareCacheDirectory(dir)
            return try SummaryCache(directory: dir, vault: vault)
        }
        try ensureCurrent(gen)
        #if DEBUG
        if let problem = cache?.loadProblem { NSLog("SempereProbe summary cache ignored: %@", problem) }
        #endif
        summaryCache = cache
        // Shown at once; the listing then corrects what changed.
        if notes.isEmpty, !listLoaded, let cached = cache?.storedSummaries, !cached.isEmpty {
            notes = Self.byTitle(cached)
        }
    }

    /// A full listing of a vault outside iCloud Drive.
    func listLocalNotes() async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        await loadGate.acquire()
        defer { loadGate.release() }
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let ids = try await offMain { try CloudVault.coordinatedRead(coordinate) { try vault.noteIDs() } }
        try ensureCurrent(gen)
        let present = Set(ids)
        notes.removeAll { !present.contains($0.id) }
        try await readSummaries(ids)
        try ensureCurrent(gen)
        summaryCache?.retain(only: present)
        saveSummaryCache()
        listLoaded = true
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
    }

    /// Reads the summaries of `ids` in batches of `loadBatchSize` on
    /// `loadConcurrency` threads, merging each batch into `notes` as it
    /// finishes and counting in `loading`. Cached summaries (unchanged
    /// revision files) cost no decryption. Publishes nothing once the vault
    /// closed (`CancellationError`) or, for the sync loop, once its task is
    /// cancelled.
    func readSummaries(_ ids: [UUID], onBatch: (([NoteSummary]) -> Void)? = nil) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        guard !ids.isEmpty else { return }
        let gen = generation
        let cache = summaryCache
        let coordinate = coordinationURL
        let width = max(1, loadConcurrency)
        let known = Set(notes.map(\.id)).subtracting(placeholderNoteIDs)
        loading = NoteLoading(done: 0, total: ids.count, refreshing: ids.allSatisfy(known.contains))
        defer { if gen == generation { loading = nil } }
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(ids.count, start + max(1, loadBatchSize))])
            let read = try await offMain {
                try CloudVault.coordinatedRead(coordinate) {
                    try vault.summaries(of: batch, cache: cache, maxConcurrency: width)
                }
            }
            try ensureCurrent(gen)
            try Task.checkCancellation()
            merge(read)
            onBatch?(read)
            start += batch.count
            loading?.done = start
        }
    }

    /// Puts `summaries` into `notes`, replacing older ones of the same notes.
    func merge(_ summaries: [NoteSummary]) {
        guard !summaries.isEmpty else { return }
        var byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for s in summaries { byID[s.id] = s }
        notes = Self.byTitle(Array(byID.values))
    }

    /// Writes the summary cache in the background; a failure only costs the
    /// next launch time.
    func saveSummaryCache() {
        guard let cache = summaryCache, cache.hasChanges else { return }
        Task.detached(priority: .utility) { try? cache.save() }
    }

    /// Creates the cache folder, excluded from device backups (the cache is
    /// rebuilt from the vault whenever it is missing).
    nonisolated static func prepareCacheDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
    }

    nonisolated static func byTitle(_ list: [NoteSummary]) -> [NoteSummary] {
        list.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }
}
