import Foundation
import Sempere

/// How old autosaves must be before thinning removes them (format.md
/// §5.8.4): kept in `UserDefaults` on this device. 0 means never.
enum ThinningPreference {
    static let key = "Sempere.thinAfterDays"
    /// Default: 30 days (maintainer decision, 2026-10-06).
    static let defaultDays = 30
    /// The choices the settings offer, 0 last ("Never").
    static let choices = [7, 14, 30, 90, 365, 0]
    /// Seconds between automatic runs on one vault.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Days, or 0 for never; a stored value outside `choices` reads as its nearest sane value.
    static var days: Int {
        get {
            guard let n = UserDefaults.standard.object(forKey: key) as? Int else { return defaultDays }
            return n <= 0 ? 0 : min(n, 3650)
        }
        set { UserDefaults.standard.set(max(newValue, 0), forKey: key) }
    }

    /// "30 days", "1 year", "Never".
    static func label(_ days: Int) -> String {
        switch days {
        case ...0: return "Never"
        case 365: return "1 year"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// `UserDefaults` key of the last automatic run on vault `id`.
    static func lastRunKey(_ id: UUID) -> String { "Sempere.lastThinning.\(id.uuidString.lowercased())" }

    /// Whether an automatic run is due: thinning is on and the last run on
    /// this vault was `interval` or more ago (or never, or in the future).
    static func isDue(days: Int, lastRun: Date?, now: Date) -> Bool {
        guard days > 0 else { return false }
        guard let lastRun, lastRun <= now else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

/// What thinning does (or would do) to one note.
struct NoteThinning: Hashable, Sendable, Identifiable {
    let id: UUID
    var title: String
    /// Revision files deleted (or that would be).
    var deletions: Int
    /// Snapshots written first (or that would be).
    var snapshots: Int
    var bytesDeleted: Int
    var bytesAdded: Int
}

/// The outcome of a thinning pass over the vault.
struct ThinningReport: Hashable, Sendable {
    /// Notes with something to remove, by title.
    var notes: [NoteThinning] = []
    /// Notes left alone, with why (open in an editor, not downloaded, unreadable revision).
    var skipped: [UUID: String] = [:]

    var deletions: Int { notes.reduce(0) { $0 + $1.deletions } }
    var snapshots: Int { notes.reduce(0) { $0 + $1.snapshots } }
    var bytesDeleted: Int { notes.reduce(0) { $0 + $1.bytesDeleted } }
    var bytesAdded: Int { notes.reduce(0) { $0 + $1.bytesAdded } }
    var isEmpty: Bool { notes.isEmpty }
}

extension NoteWriter {
    /// Plans compacting one note in `mode` as this device (format.md §5.8.4)
    /// and, unless `dryRun`, carries it out: the snapshots first, then the
    /// deletions, inside one coordinated write of the note's folder in
    /// iCloud Drive. Planning ticks the device clock on its actor, so the
    /// snapshots' readings never repeat; a dry run forgets the ticks.
    /// `verify` runs inside the read and again inside the write, and throws
    /// to refuse a note whose files are not all local.
    static func compact(_ noteID: UUID, mode: CompactionMode, vault: Vault, clock: DeviceClock, app: String = NoteWriter.appName,
                        coordinated: Bool, verify: (@Sendable () throws -> Void)?, dryRun: Bool,
                        now: Date = Date()) async throws -> (plan: CompactionPlan, deleted: Int, added: Int) {
        let folder = coordinated ? vault.url.appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true) : nil
        let loaded = try await Task.detached(priority: .utility) {
            try CloudVault.coordinatedRead(coordinated ? vault.url : nil) { () throws -> LoadedNote in
                try verify?()
                let loaded = try vault.loadNote(noteID)
                try verify?()
                return loaded
            }
        }.value
        let device = clock.device
        let plan = try await clock.withClock(save: !dryRun) { c in
            try vault.planCompaction(noteID, loaded: loaded, mode: mode, now: now, device: device, clock: &c, app: app)
        }
        return try await Task.detached(priority: .utility) {
            let deleted = vault.deletedBytes(plan)
            let added = try vault.addedBytes(plan)
            if !dryRun, !plan.isEmpty {
                try CloudVault.coordinatedWrite(folder) {
                    try verify?()
                    try vault.execute(plan)
                }
            }
            return (plan, deleted, added)
        }.value
    }
}

extension AppModel {
    /// Thins every note of the open vault (format.md §5.8.4): in revisions
    /// older than `days`, keeps checkpoints and each editing session's newest
    /// autosave, deletes the rest after writing the snapshots that keep them
    /// complete. With `dryRun`, only says what it would do ("Thin Now"'s
    /// preview). Open notes are saved first and thinned too, unless
    /// `skipOpen` (the automatic run leaves them alone). In iCloud Drive a
    /// note whose files are not all local is skipped, never downloaded.
    /// One note's failure skips that note; the others go on.
    func thinVault(days: Int, dryRun: Bool, skipOpen: Bool = false, now: Date = Date()) async throws -> ThinningReport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        guard days > 0 else { return ThinningReport() }
        let gen = generation
        let open = Set([editor?.noteID].compactMap { $0 } + windowEditors.keys)
        if !skipOpen {
            await editor?.flush()
            for e in windowEditors.values { await e.flush() }
        }
        await editGate.acquire()
        defer { editGate.release() }
        let clock = try deviceClockForWriting()
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
        let titles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let ids = try await offMain(priority: .utility) { try vault.noteIDs() }
        try ensureCurrent(gen)
        var report = ThinningReport()
        var changed: [UUID] = []
        for id in ids {
            if skipOpen, open.contains(id) { report.skipped[id] = "open"; continue }
            var verify: (@Sendable () throws -> Void)?
            if cloud {
                verify = { @Sendable in try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
            }
            do {
                let (plan, deleted, added) = try await NoteWriter.compact(id, mode: .thin(olderThan: Double(days) * 86_400),
                                                                          vault: vault, clock: clock, coordinated: cloud,
                                                                          verify: verify, dryRun: dryRun, now: now)
                try ensureCurrent(gen)
                guard !plan.deletions.isEmpty else { continue }
                report.notes.append(NoteThinning(id: id, title: titles[id] ?? "", deletions: plan.deletions.count,
                                                 snapshots: plan.snapshots.count, bytesDeleted: deleted, bytesAdded: added))
                if !dryRun { changed.append(id) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ensureCurrent(gen)
                report.skipped[id] = "\(error)"
            }
        }
        report.notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !changed.isEmpty {
            try? await refresh(changed)
            for id in changed where open.contains(id) && !skipOpen { try? await reopenEditor(ifShowing: id) }
        }
        return report
    }

    /// Runs thinning in the background when it is on and has not run on this
    /// vault in the last day (`ThinningPreference`). Only an `AppModel` built
    /// with `automaticThinning` does this, so tests write nothing unasked.
    func thinIfDue(now: Date = Date()) {
        guard automaticThinning, phase == .unlocked, let id = vault?.vaultId else { return }
        #if DEBUG
        // Scripted runs (screenshots, device probes) must not change the vault they open.
        if DemoLaunch.isActive || DebugLaunch.isActive { return }
        #endif
        let days = ThinningPreference.days
        let key = ThinningPreference.lastRunKey(id)
        guard ThinningPreference.isDue(days: days, lastRun: UserDefaults.standard.object(forKey: key) as? Date, now: now)
        else { return }
        UserDefaults.standard.set(now, forKey: key)
        let gen = generation
        Task(priority: .background) { [weak self] in
            guard let self, self.generation == gen else { return }
            _ = try? await self.thinVault(days: days, dryRun: false, skipOpen: true, now: now)
        }
    }
}
