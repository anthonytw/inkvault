import Foundation
import Sempere

/// One note's revisions as read for the history browser: loaded once, so
/// previewing several restore points does not decrypt the note again.
struct HistoryData: Sendable {
    let noteID: UUID
    let revisions: [Revision]
    /// Listed revisions that could not be read.
    let unreadable: [RevisionName]
    /// This installation's device id, for "This device" labels.
    let thisDevice: DeviceID?
    /// Restore points, oldest first (`NoteHistory.restorePoints`). Computed
    /// once: the views read it on every update.
    let points: [RestorePoint]
    /// The rows to show, newest first.
    let entries: [HistoryEntry]

    init(noteID: UUID, revisions: [Revision], unreadable: [RevisionName], thisDevice: DeviceID?) {
        self.noteID = noteID
        self.revisions = revisions
        self.unreadable = unreadable
        self.thisDevice = thisDevice
        points = NoteHistory.restorePoints(revisions, unreadable: unreadable)
        entries = HistoryEntry.entries(points, thisDevice: thisDevice)
    }

    /// The note as of `point`; throws `HistoryError.incompleteHistory` for a
    /// point compaction or an unreadable file made unrebuildable.
    func state(at point: RevisionName) throws -> NoteState {
        try NoteHistory.state(revisions, at: point, unreadable: unreadable)
    }

    /// The sentence that says compacted revisions are not restore points,
    /// shown when the note has a snapshot or a point cannot be rebuilt.
    var compactionNotice: String? { HistoryEntry.compactionNotice(points) }
}

/// A restore point as a row of the history list.
struct HistoryEntry: Identifiable, Hashable, Sendable {
    let point: RestorePoint
    /// The newest restore point: what the note is now.
    let isLatest: Bool
    let isThisDevice: Bool

    var id: RevisionName { point.name }
    var date: Date { point.wall }
    /// Whether the note as of this point can be shown and restored.
    var isAvailable: Bool { point.complete }

    /// "This device", or "Device " and the id's first four characters.
    var deviceLabel: String {
        isThisDevice ? "This device" : "Device \(point.device.rawValue.prefix(4))"
    }

    /// "Edit" for a delta, "Snapshot" for a snapshot.
    var kindLabel: String { point.kind == .snapshot ? "Snapshot" : "Edit" }

    /// Why the point is greyed out, when it is.
    var unavailableReason: String? {
        isAvailable ? nil : "Earlier revisions were compacted away or cannot be read, so this version cannot be rebuilt."
    }

    /// Rows for `points` (oldest first, as `NoteHistory.restorePoints` returns
    /// them), newest first.
    static func entries(_ points: [RestorePoint], thisDevice: DeviceID?) -> [HistoryEntry] {
        points.enumerated().reversed().map { i, p in
            HistoryEntry(point: p, isLatest: i == points.count - 1, isThisDevice: p.device == thisDevice)
        }
    }

    /// Compaction (format.md §5.3) deletes revisions and they are not restore
    /// points; said whenever a snapshot exists or a point is incomplete.
    static func compactionNotice(_ points: [RestorePoint]) -> String? {
        guard points.contains(where: { $0.kind == .snapshot || !$0.complete }) else { return nil }
        return "Revisions removed by compaction are not restore points and are not listed. "
            + "Versions that depend on them are greyed out and cannot be shown or restored."
    }
}

extension AppModel {
    /// Reads every revision of note `id` for the history browser. The open
    /// canvas's pending changes are saved first, so the newest row ("Current")
    /// is what the canvas shows. In iCloud Drive the note is downloaded first
    /// and the read, coordinated, refuses a note whose files are not all local
    /// (`CloudVault.requireLocal`).
    func loadHistory(for id: UUID) async throws -> HistoryData {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if let editor, editor.noteID == id { await editor.flush() }
        await windowEditors[id]?.flush()   // a note window's pending ink
        try ensureCurrent(gen)
        try await downloadNote(id)
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
        let device = try? deviceClockForWriting().device
        let data = try await offMain {
            try CloudVault.coordinatedRead(cloud ? url : nil) { () throws -> HistoryData in
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                let loaded = try vault.loadNote(id)
                if cloud { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
                return HistoryData(noteID: id, revisions: loaded.revisions, unreadable: Array(loaded.failures.keys),
                                   thisDevice: device)
            }
        }
        try ensureCurrent(gen)
        return data
    }

    /// A read-only editor showing the note as of `point`, for the preview. It
    /// has no writer: nothing the user does with it can reach the vault.
    func historyPreview(_ data: HistoryData, at point: RevisionName) async throws -> NoteEditor {
        let gen = generation
        let state = try await offMain { try data.state(at: point) }
        try ensureCurrent(gen)
        return NoteEditor(noteID: data.noteID, state: state, writer: nil,
                          readOnlyReason: "Preview of an earlier version. Nothing here can be edited.")
    }

    /// Restores note `id` to `point` with one delta (`NoteWriter.restore`),
    /// serialised with the other edits. The open note's pending canvas
    /// changes are saved first (so they are part of the history that is kept,
    /// not written over the restore later), and the open canvas is reopened
    /// from the restored state.
    ///
    /// - Returns: what changed, or nil when the note already matched `point`.
    @discardableResult
    func restoreVersion(of id: UUID, to point: RevisionName) async throws -> RestoreSummary? {
        try await downloadNote(id)
        if let editor, editor.noteID == id {
            await editor.flush()
            if let failure = editor.saveError { throw ModelError.unsavedChanges(failure) }
        }
        if let windowed = windowEditors[id] {   // the same for the note's own window
            await windowed.flush()
            if let failure = windowed.saveError { throw ModelError.unsavedChanges(failure) }
        }
        var result: (name: RevisionName, summary: RestoreSummary)?
        try await commit(ids: [id]) { vault, clock, cloud, verifier in
            result = try await NoteWriter.restore(id, to: point, vault: vault, clock: clock, coordinated: cloud,
                                                  verify: verifier(id))
        }
        guard let result else { return nil }
        try await reopenEditor(ifShowing: id)
        return result.summary
    }
}
