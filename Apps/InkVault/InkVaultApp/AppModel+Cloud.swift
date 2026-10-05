import InkVault
import Foundation

/// Vaults in iCloud Drive (docs/io.md): fetch placeholder files before
/// reading, show progress, and let the user cancel the wait.
extension AppModel {
    /// The URL to coordinate vault reads and writes on: the vault folder
    /// when it is in iCloud Drive, nil otherwise.
    var coordinationURL: URL? {
        isCloudVault ? vaultURL : nil
    }

    /// Downloads the files of the vault at `url` (by default only those needed
    /// to unlock; the notes follow progressively, `loadNotes`) that iCloud Drive holds
    /// only as a placeholder, publishing `cloudProgress` while it waits.
    /// Security-scoped access to `url` must be active.
    ///
    /// - Returns: whether the vault is in iCloud Drive (false: nothing done).
    /// - Throws: `CancellationError` after `cancelCloudDownload()`;
    ///   `CloudVault.CloudError` on a stall or download error.
    func fetchFromICloud(_ url: URL, scope: CloudVault.Scope = .essentials) async throws -> Bool {
        cloudTask?.cancel()
        let hooks = cloudHooks
        let task = Task.detached(priority: .userInitiated) {
            try await CloudVault.download(vault: url, scope: scope, hooks: hooks) { progress in
                await self.showCloudProgress(progress)
            }
        }
        cloudTask = task
        defer {
            if cloudTask == task {
                cloudTask = nil
                cloudProgress = nil
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Stops waiting for iCloud; the open or reload that waited fails
    /// silently with `CancellationError`.
    func cancelCloudDownload() {
        cloudTask?.cancel()
        cloudTask = nil
        cloudProgress = nil
    }

    private func showCloudProgress(_ progress: CloudProgress) {
        guard cloudTask != nil else { return }
        cloudProgress = progress
    }
}

// MARK: - Progressive note loading

extension AppModel {
    /// How the cloud sync loop ends.
    private enum SyncEnd { case settled, stalled }

    /// One progressive pass over the notes (`ProgressiveLoad`): summaries of
    /// the notes whose files are local are read and merged into `notes`, the
    /// rest are listed as placeholders (`placeholderNoteIDs`) until their files
    /// arrive. `full` re-reads every ready note (a reload); otherwise only
    /// notes not yet summarised are read.
    ///
    /// - Returns: how many notes are still downloading.
    @discardableResult
    func loadNotes(full: Bool) async throws -> Int {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        let hooks = cloudHooks
        let url = vault.url
        let priority = selectedNoteID
        let window = cloudWindow
        let pass = try await offMain { try ProgressiveLoad.pass(vault: url, priority: priority, window: window, hooks: hooks) }
        try ensureCurrent(gen)
        let have = Set(notes.map(\.id)).subtracting(placeholderNoteIDs)
        let wasPending = pendingNoteIDs
        let toRead = full ? pass.ready : pass.ready.filter { !have.contains($0) || wasPending.contains($0) }
        let coordinate = coordinationURL
        let read = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { try toRead.map { try vault.summary(of: $0) } }
        }
        try ensureCurrent(gen)
        var byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for summary in read { byID[summary.id] = summary }
        let present = Set(pass.all)
        for id in byID.keys where !present.contains(id) { byID[id] = nil }   // deleted remotely
        var placeholders = Set<UUID>()
        let previousPlaceholders = placeholderNoteIDs
        for id in pass.pending where byID[id] == nil || previousPlaceholders.contains(id) {
            byID[id] = NoteSummary(id: id, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0,
                                   modified: nil, problem: nil)
            placeholders.insert(id)
        }
        for id in pass.ready { placeholders.remove(id) }
        notes = byID.values.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
        placeholderNoteIDs = placeholders
        pendingNoteIDs = Set(pass.pending)
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
        if let failure = pass.failures.first?.value, cloudFailure != failure { cloudFailure = failure }
        return pass.pending.count
    }

    /// Keeps passing (`loadNotes`) until no note is pending and the note set
    /// has held still for `cloudSettlePasses` passes (iCloud lists folder
    /// contents gradually, so one pass can miss notes), or until nothing has
    /// arrived for `cloudStallTimeout`. Replaces a loop already running.
    func startCloudSync() {
        guard isCloudVault else { return }
        cloudSyncTask?.cancel()
        let gen = generation
        cloudSyncTask = Task { [weak self] in
            var quiet = 0
            var lastPending = Int.max
            var lastKnown = -1
            let clock = ContinuousClock()
            var lastChange = clock.now
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                do {
                    let pending = try await self.loadNotes(full: false)
                    let known = self.notes.count
                    if pending != lastPending || known != lastKnown { lastChange = clock.now }
                    quiet = (pending == 0 && known == lastKnown) ? quiet + 1 : 0
                    lastPending = pending
                    lastKnown = known
                    if quiet >= self.cloudSettlePasses { return }
                    if pending > 0, clock.now - lastChange > self.cloudStallTimeout {
                        self.errorMessage = "iCloud Drive has not delivered \(pending) note\(pending == 1 ? "" : "s") for "
                            + "\(Int(self.cloudStallTimeout.components.seconds)) seconds. Check that this iPad is online and "
                            + "signed in to iCloud Drive; pull down on the list to try again."
                        return
                    }
                    try await Task.sleep(for: self.cloudPollInterval)
                } catch is CancellationError {
                    return
                } catch {
                    self.errorMessage = "\(error)"
                    return
                }
            }
        }
    }

    func stopCloudSync() {
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        pendingNoteIDs = []
        placeholderNoteIDs = []
        cloudFailure = nil
    }

    /// Fetches one note ahead of the others (the user opened it), then reads
    /// its summary. No-op for notes that are already local.
    func downloadNote(_ id: UUID) async throws {
        guard isCloudVault, let url = vaultURL, pendingNoteIDs.contains(id) else { return }
        let gen = generation
        let hooks = cloudHooks
        let items = try await offMain {
            try CloudScan.noteGroups(inVault: url).first { $0.id == id }?.items ?? []
        }
        try ensureCurrent(gen)
        try await CloudVault.download(items: items, hooks: hooks) { _ in }
        try ensureCurrent(gen)
        try await refresh([id])
        pendingNoteIDs.remove(id)
        placeholderNoteIDs.remove(id)
    }
}
