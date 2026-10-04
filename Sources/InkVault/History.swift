import Foundation

// MARK: - History and restore (docs/format.md §5.7)
//
// A restore point is a revision. The note "as of" a revision is the merge
// (`NoteReducer`) of every revision ordered at or before it by
// `(hlc, device, seq)`. Restoring writes one new delta that turns the current
// state into that historical state; history itself is never rewritten.

/// One revision a note can be viewed or restored at.
public struct RestorePoint: Hashable, Sendable {
    /// The revision's file name; orders restore points by `(hlc, device, seq)`.
    public var name: RevisionName
    /// The revision's `wall` time (informational, format.md §5.1).
    public var wall: Date
    /// The revision's `app` field (informational).
    public var app: String
    /// False when the note as of this revision cannot be rebuilt: a revision
    /// ordered before it was deleted by compaction and no snapshot at or
    /// before this point covers it, or one ordered before it is unreadable.
    public var complete: Bool

    public init(name: RevisionName, wall: Date, app: String, complete: Bool) {
        self.name = name; self.wall = wall; self.app = app; self.complete = complete
    }

    /// The revision's hybrid logical clock reading.
    public var hlc: HLC { name.hlc }
    /// The device that wrote the revision.
    public var device: DeviceID { name.device }
    /// Delta or snapshot.
    public var kind: RevisionName.Kind { name.kind }
}

/// Errors from viewing or restoring history.
public enum HistoryError: Error, Hashable, Sendable {
    /// No readable revision of the note matches; the payload is what was asked for.
    case unknownRevision(String)
    /// Several revisions match a prefix.
    case ambiguousRevision(String, [RevisionName])
    /// The note as of this revision cannot be rebuilt (see `RestorePoint.complete`).
    case incompleteHistory(RevisionName)
}

/// What a restore changes, counted from its ops.
public struct RestoreSummary: Hashable, Sendable, Codable {
    /// Pages removed because they did not exist at the restore point.
    public var pagesRemoved = 0
    /// Pages re-created (new ids, `parent` = the old id).
    public var pagesRestored = 0
    /// Strokes removed because they did not exist at the restore point.
    public var strokesRemoved = 0
    /// Strokes re-created (new ids, `parent` = the old id).
    public var strokesRestored = 0
    /// Pages whose order key is set back.
    public var pageOrderChanges = 0
    /// Pages whose recognised text is set back (or cleared).
    public var recognitionChanges = 0
    /// Metadata fields set back, by name (`title`, `tags`, ...).
    public var metaFields: [String] = []
    /// `true` when the restore deletes the note, `false` when it undeletes it.
    public var deleted: Bool?

    public init() {}

    /// Counts `ops` as `NoteHistory.restoreOps` emits them.
    public init(_ ops: [Op]) {
        var newPages = Set<UUID>()
        for case .addPage(let p) in ops { newPages.insert(p.id) }
        for op in ops {
            switch op {
            case .removePage: pagesRemoved += 1
            case .addPage: pagesRestored += 1
            case .removeStroke: strokesRemoved += 1
            case .addStroke: strokesRestored += 1
            case .setPageOrder: pageOrderChanges += 1
            case .setPageRecognition(let id, _):
                // A re-created page's recognition is part of re-creating it.
                if !newPages.contains(id) { recognitionChanges += 1 }
            case .setMeta(let change): metaFields.append(change.field)
            case .deleteNote: deleted = true
            case .restoreNote: deleted = false
            }
        }
    }

    /// True when nothing changes.
    public var isEmpty: Bool { self == RestoreSummary() }
}

/// The outcome of `Vault.restore`.
public struct RestoreResult: Hashable, Sendable {
    /// The restore point.
    public var target: RevisionName
    /// The delta that makes the current state equal the restore point's; nil
    /// when the note already matches it (nothing to write).
    public var delta: Revision?
    /// True when `delta` was written to the vault (false on a dry run).
    public var written: Bool
    /// What `delta` changes.
    public var summary: RestoreSummary
}

/// History over a note's revisions: restore points, the state as of one, and
/// the delta that restores it. Pure; reading and writing files is in `Vault`.
public enum NoteHistory {
    /// One restore point per readable revision, ordered by `(hlc, device, seq)`.
    ///
    /// Revisions deleted by compaction are not restore points. A surviving
    /// revision is `complete` only if the note as of it can still be rebuilt
    /// (see `RestorePoint.complete`).
    ///
    /// - Parameter unreadable: listed revisions that could not be read; any
    ///   point at or after one of them is incomplete.
    public static func restorePoints(_ revisions: [Revision], unreadable: [RevisionName] = []) -> [RestorePoint] {
        let check = Completeness(revisions, unreadable: unreadable)
        return revisions.sorted { $0.name < $1.name }.map { r in
            RestorePoint(name: r.name, wall: r.wall, app: r.app, complete: check.isComplete(at: r.name))
        }
    }

    /// The note as of restore point `point`: the merge of every revision
    /// ordered at or before it (`NoteReducer.reconstruct`).
    ///
    /// - Throws: `HistoryError.unknownRevision` if no revision has that name,
    ///   `.incompleteHistory` if the state cannot be rebuilt, or `NoteLogError`.
    public static func state(_ revisions: [Revision], at point: RevisionName,
                             unreadable: [RevisionName] = []) throws -> NoteState {
        guard revisions.contains(where: { $0.name == point }) else {
            throw HistoryError.unknownRevision(point.filename)
        }
        guard Completeness(revisions, unreadable: unreadable).isComplete(at: point) else {
            throw HistoryError.incompleteHistory(point)
        }
        return try NoteReducer.reconstruct(revisions.filter { $0.name <= point })
    }

    /// The ops of one delta that turns `current` into `target` (format.md §5.7).
    ///
    /// Pages and strokes correspond by id, or by `parent` (an earlier restore's
    /// copy, with the same ink, points and transform for a stroke), so
    /// restoring the same point twice yields no ops. Items of `current` with
    /// no counterpart are removed; items of `target` with none are re-added
    /// under a new id from `newID` with `parent` set to the old id. Page order,
    /// recognition, metadata and `deleted` are set where they differ.
    public static func restoreOps(current: NoteState, target: NoteState,
                                  newID: () -> UUID = { UUID() }) -> [Op] {
        var ops: [Op] = []
        if current.deleted && !target.deleted { ops.append(.restoreNote) }
        for key in NoteState.ClockKey.allCases {
            guard case .meta(let want) = RegisterValue(key, in: target),
                  case .meta(let have) = RegisterValue(key, in: current), want != have else { continue }
            ops.append(.setMeta(want))
        }

        // Pages: exact ids first, then earlier restores' copies.
        var counterpart: [UUID: Page] = [:]
        var taken = Set<UUID>()
        let currentIds = Set(current.pages.map(\.id))
        for t in target.pages where currentIds.contains(t.id) {
            counterpart[t.id] = current.pages.first { $0.id == t.id }
            taken.insert(t.id)
        }
        for t in target.pages where counterpart[t.id] == nil {
            if let c = current.pages.first(where: { $0.parent == t.id && !taken.contains($0.id) }) {
                counterpart[t.id] = c
                taken.insert(c.id)
            }
        }
        for c in current.pages where !taken.contains(c.id) { ops.append(.removePage(pageId: c.id)) }

        func copy(_ s: Stroke) -> Stroke {
            Stroke(id: newID(), ink: s.ink, points: s.points, transform: s.transform, parent: s.id)
        }
        for t in target.pages {
            guard let c = counterpart[t.id] else {
                let page = Page(id: newID(), order: t.order, parent: t.id)
                ops.append(.addPage(page))
                for s in t.strokes { ops.append(.addStroke(page: page.id, stroke: copy(s))) }
                if let r = t.recognition { ops.append(.setPageRecognition(pageId: page.id, recognition: r)) }
                continue
            }
            if c.order != t.order { ops.append(.setPageOrder(pageId: c.id, order: t.order)) }
            var matched = Set<UUID>()      // target stroke ids with a counterpart
            var used = Set<UUID>()         // current stroke ids that are one
            let held = Set(c.strokes.map(\.id))
            for s in t.strokes where held.contains(s.id) {
                matched.insert(s.id)
                used.insert(s.id)
            }
            for s in t.strokes where !matched.contains(s.id) {
                if let hit = c.strokes.first(where: { !used.contains($0.id) && $0.parent == s.id && sameInk($0, s) }) {
                    matched.insert(s.id)
                    used.insert(hit.id)
                }
            }
            for s in c.strokes where !used.contains(s.id) { ops.append(.removeStroke(page: c.id, strokeId: s.id)) }
            for s in t.strokes where !matched.contains(s.id) { ops.append(.addStroke(page: c.id, stroke: copy(s))) }
            if c.recognition != t.recognition {
                ops.append(.setPageRecognition(pageId: c.id, recognition: t.recognition))
            }
        }
        if !current.deleted && target.deleted { ops.append(.deleteNote) }
        return ops
    }

    /// Same drawing: ink, control points and transform (identity when absent).
    static func sameInk(_ a: Stroke, _ b: Stroke) -> Bool {
        a.ink == b.ink && a.points == b.points && (a.transform ?? .identity) == (b.transform ?? .identity)
    }

    /// The delta that restores the note to `point`, or nil when the current
    /// state (the merge of all `revisions`) already matches it. `revisions`
    /// must be every revision of the note. `clock` observes each of them
    /// first, so the delta's LWW stamp beats every op it sets back.
    ///
    /// - Throws: as `state(_:at:)`, or `NoteLogError`.
    public static func makeRestore(from revisions: [Revision], to point: RevisionName, device: DeviceID,
                                   clock: inout HybridClock, wall: Date, app: String,
                                   newID: () -> UUID = { UUID() }) throws -> Revision? {
        let target = try state(revisions, at: point)
        let current = try NoteReducer.reconstruct(revisions)
        let ops = restoreOps(current: current, target: target, newID: newID)
        guard !ops.isEmpty else { return nil }
        for r in revisions { clock.observe(r.hlc, wall: wall) }
        let hlc = clock.tick(wall: wall)
        return Revision(noteId: revisions[0].noteId, device: device, seq: Vault.nextSeq(from: revisions, device: device),
                        hlc: hlc, wall: wall, app: app, body: .delta(ops: ops))
    }

    /// Picks a revision by file name (`<hlc>-<device>-<seq>.<kind>.age`), by
    /// that name without its `.<kind>.age` suffix, or by a unique prefix of
    /// at least 6 characters of it.
    ///
    /// - Throws: `HistoryError.unknownRevision` or `.ambiguousRevision`.
    public static func resolve(_ query: String, among names: [RevisionName]) throws -> RevisionName {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let hit = names.first(where: { $0.filename == q }) { return hit }
        func stem(_ n: RevisionName) -> String { "\(n.hlc)-\(n.device)-\(n.seq)" }
        if let hit = names.first(where: { stem($0) == q }) { return hit }
        guard q.count >= 6 else { throw HistoryError.unknownRevision(query) }
        let hits = names.filter { $0.filename.hasPrefix(q) }
        guard let first = hits.first else { throw HistoryError.unknownRevision(query) }
        guard hits.count == 1 else { throw HistoryError.ambiguousRevision(query, hits) }
        return first
    }
}

/// Decides whether the note as of a revision can be rebuilt from the
/// revisions that are left.
///
/// Compaction deletes only revisions some snapshot covers (format.md §5.3),
/// so the gone ones are the `(device, seq)` some snapshot's `included` lists
/// but no file has. The state as of point P is complete when each gone
/// revision is covered by a snapshot ordered at or before P, or provably
/// ordered after P: P itself or a surviving revision ordered after it, of the
/// same device with a smaller `seq`, comes before it (a device's clock and
/// `seq` both only grow).
///
/// An unreadable snapshot may be the only record of revisions compacted
/// away, so it makes every point incomplete. Coverage is compared as ranges,
/// never enumerated: `upTo` comes from a file and may be huge.
struct Completeness {
    var snapshots: [(name: RevisionName, included: Included)] = []
    var listed: [RevisionName]
    var unreadable: [RevisionName]
    /// Every seq in some file name, per device.
    var present: [DeviceID: Set<Int>] = [:]
    /// The union of every readable snapshot's `included`.
    var covered = Included()

    init(_ revisions: [Revision], unreadable: [RevisionName]) {
        listed = revisions.map(\.name) + unreadable
        self.unreadable = unreadable
        for n in listed { present[n.device, default: []].insert(n.seq) }
        for r in revisions {
            guard case .snapshot(let included, _) = r.body else { continue }
            snapshots.append((r.name, included))
            covered = covered.union(included)
        }
    }

    func isComplete(at point: RevisionName) -> Bool {
        if unreadable.contains(where: { $0 <= point || $0.kind == .snapshot }) { return false }
        let before = snapshots.filter { $0.name <= point }.reduce(Included()) { $0.union($1.included) }
        // Smallest seq per device at or after `point`: its device's higher seqs come later.
        var firstAtOrAfter: [DeviceID: Int] = [:]
        for n in listed where n >= point { firstAtOrAfter[n.device] = min(firstAtOrAfter[n.device] ?? .max, n.seq) }
        for (device, all) in covered.entries {
            let have = present[device] ?? []
            let known = before.entries[device] ?? Included.Entry()
            // Gone seqs that matter: covered somewhere, no file, below `limit`.
            let limit = firstAtOrAfter[device] ?? .max
            func needs(_ seq: Int) -> Bool { seq < limit && !have.contains(seq) && !known.covers(seq) }
            if all.extra.contains(where: needs) { return false }
            // The run (known.upTo, min(all.upTo, limit - 1)] must be all files or known extras.
            let top = min(all.upTo, limit - 1)
            if known.upTo < top {
                let length = top - known.upTo
                let filled = have.count { $0 > known.upTo && $0 <= top }
                    + known.extra.count { $0 > known.upTo && $0 <= top && !have.contains($0) }
                if filled < length { return false }
            }
        }
        return true
    }
}

// MARK: - Vault

extension LoadedNote {
    /// `NoteHistory.restorePoints` over what was loaded; unreadable revisions
    /// make every point at or after them incomplete.
    public var restorePoints: [RestorePoint] {
        NoteHistory.restorePoints(revisions, unreadable: Array(failures.keys))
    }

    /// The note as of `point` (`NoteHistory.state`). Unreadable revisions
    /// ordered after `point` do not matter; one before it throws
    /// `HistoryError.incompleteHistory`.
    public func state(at point: RevisionName) throws -> NoteState {
        try NoteHistory.state(revisions, at: point, unreadable: Array(failures.keys))
    }
}

extension Vault {
    /// The note's restore points, oldest first (`NoteHistory.restorePoints`).
    public func restorePoints(noteId: UUID) throws -> [RestorePoint] {
        try loadNote(noteId).restorePoints
    }

    /// The note as of restore point `point` (`NoteHistory.state`).
    public func state(noteId: UUID, at point: RevisionName) throws -> NoteState {
        try loadNote(noteId).state(at: point)
    }

    /// Restores a note to `point` by writing one new delta (format.md §5.7)
    /// with the next free `seq` for `device`; nothing is written when the
    /// note already matches the point or when `dryRun` is set.
    ///
    /// - Throws: `VaultError.revision` if any revision of the note is
    ///   unreadable (the current state must be known exactly),
    ///   `HistoryError`, `NoteLogError`, or a write error.
    @discardableResult
    public func restore(note noteId: UUID, toRevision point: RevisionName, device: DeviceID,
                        clock: inout HybridClock, wall: Date = Date(), app: String,
                        dryRun: Bool = false) throws -> RestoreResult {
        let revs = try Self.strictRevisions(of: try loadNote(noteId))
        let delta = try NoteHistory.makeRestore(from: revs, to: point, device: device, clock: &clock,
                                                wall: wall, app: app)
        if let delta, !dryRun { try write(delta) }
        return RestoreResult(target: point, delta: delta, written: delta != nil && !dryRun,
                             summary: RestoreSummary(delta.map(\.ops) ?? []))
    }
}
