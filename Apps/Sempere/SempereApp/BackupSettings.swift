import Foundation
import Sempere

/// This device's backup settings and last results for one vault (Settings →
/// Backups, docs/io.md "Backups"). Kept in `UserDefaults` under the vault's
/// id, never in the vault: the folder is this device's, and a backup holds
/// one vault (`Backup.run` refuses another vault's backup folder).
struct BackupRecord: Codable, Equatable, Sendable {
    /// Bookmark of the folder the user picked. Access granted to a picked
    /// folder covers what is inside it, so the backup may be a subfolder.
    var bookmark: Data?
    /// The picked folder's name, for display.
    var folderName: String?
    /// The backup folder inside the picked one (`BackupLocation`), nil when
    /// the picked folder is the backup itself.
    var subfolder: String?
    /// The last run that finished without a file error.
    var lastBackup: Date?
    /// Notes, files and bytes the backup held after that run (`BackupStatus`).
    var lastNotes: Int?
    var lastFiles: Int?
    var lastBytes: Int?
    /// File errors of the last run (0 when it finished cleanly).
    var lastErrors: Int?
    /// The last Verify Backup and whether it found the backup healthy.
    var lastVerified: Date?
    var lastVerifyHealthy: Bool?
    /// Remind after this many days without a backup; 0 = off.
    var reminderDays = 0
    /// When the reminder was switched on: what it counts from while there
    /// has been no backup yet.
    var reminderSince: Date?

    /// The folder for display: "Drive/Notes Backup", or nil when none is set.
    var displayPath: String? {
        guard let folderName else { return nil }
        return subfolder.map { "\(folderName)/\($0)" } ?? folderName
    }
}

/// Reads and writes `BackupRecord`s (one `UserDefaults` key per vault).
struct BackupStore {
    var defaults: UserDefaults = .standard

    static func key(_ vaultId: UUID) -> String { "Sempere.backup.\(vaultId.uuidString.lowercased())" }

    /// The vault's record; an empty one when none is stored or it cannot be read.
    func record(for vaultId: UUID) -> BackupRecord {
        guard let data = defaults.data(forKey: Self.key(vaultId)),
              let record = try? JSONDecoder().decode(BackupRecord.self, from: data) else { return BackupRecord() }
        return record
    }

    func save(_ record: BackupRecord, for vaultId: UUID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key(vaultId))
    }
}

/// Where a backup goes inside the folder the user picked, and which folder a
/// restore reads.
enum BackupLocation {
    enum Problem: Error, Equatable, CustomStringConvertible {
        /// The picked folder is a vault: a backup never goes inside one.
        case isVault(String)
        /// The picked folder is, holds or lies inside the open vault.
        case insideOpenVault
        /// The picked folder is a backup of another vault.
        case otherVaultsBackup(String)
        /// No folder in the pick holds a backup or a vault to restore.
        case nothingToRestore(String)
        /// The pick holds several backups or vaults.
        case severalBackups([String])

        var description: String {
            switch self {
            case .isVault(let name):
                return "“\(name)” is a vault. Choose a folder outside it (an external drive, another cloud folder)."
            case .insideOpenVault:
                return "That folder is the open vault, or inside it. A backup must be somewhere else."
            case .otherVaultsBackup(let name):
                return "“\(name)” holds the backup of another vault. Choose another folder."
            case .nothingToRestore(let name):
                return "“\(name)” holds no backup or vault. Choose the backup folder itself (it holds backup.json)."
            case .severalBackups(let names):
                return "That folder holds several backups (\(names.joined(separator: ", "))). Choose one of them."
            }
        }
    }

    /// "<vault name> Backup".
    static func folderName(forVault name: String) -> String { "\(name) Backup" }

    /// The vault id a backup folder holds, from its `backup.json`; nil for a
    /// folder that is no backup (or whose index cannot be read).
    static func backupVaultId(_ dir: URL) -> String? {
        try? Backup.status(at: dir).vaultId
    }

    static func isVault(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
    }

    static func isBackup(_ dir: URL, _ fm: FileManager) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(BackupManifest.fileName).path)
    }

    static func visibleEntries(_ dir: URL, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The subfolder of `picked` that holds (or will hold) the backup of the
    /// vault `vaultId` called `vaultName`, nil for `picked` itself:
    /// - `picked` is a backup of this vault, or empty: `picked` itself;
    /// - otherwise "<name> Backup" inside it, or "<name> Backup 2", … when
    ///   that name is taken by something else than this vault's backup.
    ///
    /// - Throws: `Problem.insideOpenVault` when `picked` overlaps `openVault`,
    ///   `.isVault` for a vault (a backup of one has `backup.json` too and is
    ///   fine), `.otherVaultsBackup` for another vault's backup.
    static func subfolder(in picked: URL, vaultId: UUID, vaultName: String, openVault: URL?,
                          fileManager fm: FileManager = .default) throws -> String? {
        if let openVault, overlaps(picked, openVault) { throw Problem.insideOpenVault }
        let id = vaultId.uuidString.lowercased()
        if isBackup(picked, fm) {
            guard backupVaultId(picked) == id else { throw Problem.otherVaultsBackup(picked.lastPathComponent) }
            return nil
        }
        if isVault(picked, fm) { throw Problem.isVault(picked.lastPathComponent) }
        if visibleEntries(picked, fm).isEmpty { return nil }
        let base = folderName(forVault: vaultName)
        for n in 1...100 {
            let name = n == 1 ? base : "\(base) \(n)"
            let dir = picked.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return name }
            guard isDir.boolValue else { continue }
            if isBackup(dir, fm) ? backupVaultId(dir) == id : (!isVault(dir, fm) && visibleEntries(dir, fm).isEmpty) {
                return name
            }
        }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// The folder a restore reads for the pick: `picked` when it holds
    /// `backup.json` or `vault.json`, else its one subfolder that does.
    static func restoreSource(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        if isBackup(picked, fm) || isVault(picked, fm) { return picked }
        let inside = visibleEntries(picked, fm).sorted().map { picked.appendingPathComponent($0, isDirectory: true) }
            .filter { isBackup($0, fm) || isVault($0, fm) }
        if inside.count == 1 { return inside[0] }
        if inside.isEmpty { throw Problem.nothingToRestore(picked.lastPathComponent) }
        throw Problem.severalBackups(inside.map(\.lastPathComponent))
    }

    /// The name offered for a restored vault: the backup folder's name
    /// without " Backup", then " (Restored)".
    static func suggestedName(forBackup source: URL) -> String {
        var name = source.deletingPathExtension().lastPathComponent
        if let r = name.range(of: #" Backup( \d+)?$"#, options: .regularExpression) { name.removeSubrange(r) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Notes" : name) + " (Restored)"
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let pa = a.standardizedFileURL.resolvingSymlinksInPath().path
        let pb = b.standardizedFileURL.resolvingSymlinksInPath().path
        return pa == pb || pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/")
    }
}

/// "Remind me if there has been no backup in N days" (a local notification).
enum BackupReminder {
    /// The choices Settings offers, 0 first ("Off").
    static let choices = [0, 1, 3, 7, 14, 30]
    /// Never fire sooner than this after scheduling (an overdue reminder
    /// fires shortly, not at once while the user looks at Settings).
    static let minimumDelay: TimeInterval = 60 * 60

    /// "Off", "After 1 day", "After 7 days".
    static func label(_ days: Int) -> String {
        days <= 0 ? "Off" : days == 1 ? "After 1 day" : "After \(days) days"
    }

    /// The notification's identifier for vault `id` (one pending per vault).
    static func identifier(_ vaultId: UUID) -> String { "Sempere.backupReminder.\(vaultId.uuidString.lowercased())" }

    /// When the reminder is due: `days` after the last backup, or after it
    /// was switched on when there was none; nil when off.
    static func dueDate(_ r: BackupRecord) -> Date? {
        guard r.reminderDays > 0, let base = r.lastBackup ?? r.reminderSince else { return nil }
        return base.addingTimeInterval(TimeInterval(min(r.reminderDays, 3650)) * 86_400)
    }

    /// Whether the reminder's time has passed (Settings shows "overdue").
    static func isOverdue(_ r: BackupRecord, now: Date) -> Bool {
        dueDate(r).map { $0 <= now } ?? false
    }

    /// When to deliver the notification: the due date, but not before
    /// `now + minimumDelay`; nil when off.
    static func fireDate(_ r: BackupRecord, now: Date) -> Date? {
        dueDate(r).map { max($0, now.addingTimeInterval(minimumDelay)) }
    }

    /// The notification's text. Names the vault, never a note.
    static func message(vaultName: String, record r: BackupRecord) -> (title: String, body: String) {
        let days = r.reminderDays == 1 ? "a day" : "\(r.reminderDays) days"
        let since = r.lastBackup == nil ? "has never been backed up" : "has not been backed up for \(days)"
        return ("Back up “\(vaultName)”", "“\(vaultName)” \(since). Open Sempere and choose Settings → Back Up Now.")
    }
}

/// Delivers backup reminders (`UNUserNotificationCenter` in the app,
/// `BackupNotifications.swift`; a fake in tests).
@MainActor
protocol BackupNotifying: AnyObject {
    /// Asks for permission to notify; true when granted.
    func authorize() async -> Bool
    /// Replaces the pending notification `id` with one at `date`.
    func schedule(id: String, at date: Date, title: String, body: String) async
    func cancel(id: String) async
}

/// Notifies nothing (the default until the app installs the real one).
@MainActor
final class NoBackupNotifier: BackupNotifying {
    func authorize() async -> Bool { false }
    func schedule(id: String, at date: Date, title: String, body: String) async {}
    func cancel(id: String) async {}
}

/// A running Back Up Now or Verify Backup, for Settings' progress line.
struct BackupProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// iCloud Drive is delivering the vault's files (`done` of `total`).
        case downloading(done: Int, total: Int)
        /// Files written to the backup so far.
        case copying(files: Int)
        case verifying
        case restoring
    }

    var stage: Stage

    var headline: String {
        switch stage {
        case let .downloading(done, total): return "Downloading from iCloud Drive: \(done) of \(total) files"
        case .copying(let n): return n == 0 ? "Backing up…" : "Backing up: \(n) file\(n == 1 ? "" : "s") written"
        case .verifying: return "Verifying the backup…"
        case .restoring: return "Restoring…"
        }
    }
}

/// Counts files a backup run wrote and carries a cancel request into it
/// (`BackupOptions.afterEachFile` runs on the backup's thread).
final class BackupRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    private var cancelled = false

    var filesWritten: Int { lock.withLock { written } }
    func cancel() { lock.withLock { cancelled = true } }

    /// Counts a file; throws `CancellationError` once `cancel()` was called.
    func fileWritten() throws {
        try lock.withLock {
            written += 1
            if cancelled { throw CancellationError() }
        }
    }
}

/// The sentences Settings → Backups and the restore sheet show.
enum BackupText {
    /// "12 notes, 3,401 files, 1.2 GB".
    static func contents(notes: Int?, files: Int?, bytes: Int?) -> String? {
        guard let notes, let files, let bytes else { return nil }
        return "\(notes) note\(notes == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s"), "
            + StorageText.bytes(Int64(clamping: bytes))
    }

    /// What one Back Up Now did.
    static func report(_ r: BackupReport) -> String {
        let written = r.copied.count + r.replaced.count
        var s = written == 0 ? "The backup was already up to date." : "\(written) file\(written == 1 ? "" : "s") backed up."
        if !r.errors.isEmpty {
            s += " \(r.errors.count) file\(r.errors.count == 1 ? "" : "s") could not be copied (\(r.errors[0].path): "
                + "\(r.errors[0].message)). Run Back Up Now again; the backup is incomplete until it succeeds."
        }
        return s
    }

    /// What one Verify Backup found; `problemLines` are listed separately.
    static func verify(_ r: BackupVerifyReport) -> String {
        let checked = r.files.filter { $0.status == .ok }.count
        if r.isHealthy {
            return "The backup is healthy: \(checked) file\(checked == 1 ? "" : "s") match their recorded checksums"
                + (r.decrypted ? ", and every note was decrypted and checked with this vault's key." : ". Notes were not decrypted (the vault is locked).")
        }
        let n = r.problemLines.count
        return "The backup has \(n) problem\(n == 1 ? "" : "s"). Run Back Up Now to replace missing or damaged files, then verify again."
    }

    /// One row of the restore preview.
    struct Row: Hashable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// The restore preview's rows.
    static func preview(_ p: RestorePreview) -> [Row] {
        var rows = [
            Row(label: "Notes", value: "\(p.notes)"),
            Row(label: "Versions", value: "\(p.revisions)"),
            Row(label: "Attachments", value: "\(p.attachments)"),
            Row(label: "Size", value: StorageText.bytes(Int64(clamping: p.bytes))),
            Row(label: "Newest Change",
                value: p.newestRevision.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None"),
        ]
        if let d = p.backupUpdated {
            rows.append(Row(label: "Backed Up", value: d.formatted(date: .abbreviated, time: .shortened)))
        }
        if !p.isBackup { rows.append(Row(label: "Kind", value: "A vault folder, not a backup")) }
        return rows
    }

    /// What a restore did.
    static func restore(_ o: RestoreOutcome) -> String {
        let r = o.report
        var s = "Restored “\(o.url.deletingPathExtension().lastPathComponent)”: \(r.restored.count + r.alreadyPresent) files."
        if !r.errors.isEmpty {
            s += " \(r.errors.count) file\(r.errors.count == 1 ? "" : "s") could not be restored (damaged or missing in the backup)."
        }
        if r.verify == nil {
            s += " The vault is not complete: restore again from another copy of the backup to finish it."
        } else if r.verify?.isHealthy == false {
            s += " The restored vault has problems; open it and check its notes."
        }
        return s
    }
}
