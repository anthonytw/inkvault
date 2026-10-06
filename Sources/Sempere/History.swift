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
    /// Pages whose own paper is set back (or cleared).
    public var pagePaperChanges = 0
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
            case .setPagePaper(let id, _):
                if !newPages.contains(id) { pagePaperChanges += 1 }
            case .setMeta(let change): metaFields.append(change.field)
            case .addTag, .removeTag: if !metaFields.contains("tags") { metaFields.append("tags") }
            case .deleteNote: deleted = true
            case .restoreNote: deleted = false
            // A1: restore does not diff items and recordings yet.
            case .addItem, .removeItem, .setItem, .addRecording, .removeRecording, .setRecording: break
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
        let sorted = revisions.sorted { $0.name < $1.name }
        let complete = Completeness(revisions, unreadable: unreadable).isComplete(at: sorted.map(\.name))
        return zip(sorted, complete).map { r, ok in RestorePoint(name: r.name, wall: r.wall, app: r.app, complete: ok) }
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
        guard Completeness(revisions, unreadable: unreadable).isComplete(at: [point]) == [true] else {
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
        for key in NoteState.ClockKey.allCases where key != .tags {
            guard case .meta(let want) = RegisterValue(key, in: target),
                  case .meta(let have) = RegisterValue(key, in: current), want != have else { continue }
            ops.append(.setMeta(want))
        }
        ops += NoteOps.setTags(target.meta.tags, on: current)

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
                if let p = t.paper { ops.append(.setPagePaper(pageId: page.id, paper: p)) }
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
            if c.paper != t.paper { ops.append(.setPagePaper(pageId: c.id, paper: t.paper)) }
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
///
/// Every input may be hostile, so all points are decided in one sweep: the
/// union of snapshots at or before the point, each device's next file name at
/// or after it and its smallest uncovered gone `extra` only ever move forward.
/// The cost is about points × devices × log plus snapshots × extras, not
/// points × extras.
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
        snapshots.sort { $0.name < $1.name }
    }

    /// The per-device state of the sweep.
    private struct Device {
        let all: Included.Entry
        let have: Set<Int>
        /// `have`, ascending.
        let haveSorted: [Int]
        /// `all.extra` without a file, ascending; `gone[..<next]` are known.
        let gone: [Int]
        var next = 0
        /// This device's listed names, ascending, and the smallest seq from each index on.
        let names: [RevisionName]
        let suffixMin: [Int]
        /// First index of `names` at or after the current point.
        var cursor = 0
        /// The `known.extra` values that are also files, ascending, for the
        /// known coverage numbered `sharedVersion` (it only changes when a
        /// snapshot is merged, so this is rebuilt at most once per snapshot).
        var shared: [Int] = []
        var sharedVersion = -1

        init(all: Included.Entry, have: Set<Int>, names: [RevisionName]) {
            self.all = all
            self.have = have
            haveSorted = have.sorted()
            gone = all.extra.filter { !have.contains($0) }
            self.names = names.sorted()
            var mins = [Int](repeating: .max, count: self.names.count)
            var m = Int.max
            for i in stride(from: self.names.count - 1, through: 0, by: -1) {
                m = min(m, self.names[i].seq)
                mins[i] = m
            }
            suffixMin = mins
        }

        /// Whether the note as of `point` lacks nothing of this device;
        /// `known` is the coverage of the snapshots at or before `point`.
        /// `version` numbers `known`: equal versions mean equal coverage.
        mutating func complete(at point: RevisionName, known: Included.Entry, version: Int) -> Bool {
            while cursor < names.count, names[cursor] < point { cursor += 1 }
            // Smallest seq at or after `point`: the device's higher seqs come later.
            let limit = cursor < names.count ? suffixMin[cursor] : .max
            // Gone extras that matter: no file, below `limit`, not known by then.
            while next < gone.count, known.covers(gone[next]) { next += 1 }
            if next < gone.count, gone[next] < limit { return false }
            // The run (known.upTo, min(all.upTo, limit - 1)] must be all files or known extras.
            let top = min(all.upTo, limit - 1)
            guard known.upTo < top else { return true }
            let length = top - known.upTo
            let files = Self.countAbove(known.upTo, upTo: top, in: haveSorted)
            let extras = Self.countAbove(known.upTo, upTo: top, in: known.extra)
            if files + extras < length { return false }
            // Exact: known extras that are also files count once. Not a scan
            // per point: `known.extra` may be huge and points many.
            if sharedVersion != version {
                shared = known.extra.filter { have.contains($0) }
                sharedVersion = version
            }
            let both = Self.countAbove(known.upTo, upTo: top, in: shared)
            return files + extras - both >= length
        }

        /// How many of the ascending `xs` lie in `(low, high]` (all of `known.extra` is above `known.upTo`).
        static func countAbove(_ low: Int, upTo high: Int, in xs: [Int]) -> Int {
            func firstAbove(_ v: Int) -> Int {
                var lo = 0, hi = xs.count
                while lo < hi {
                    let mid = lo + (hi - lo) / 2
                    if xs[mid] <= v { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }
            return max(firstAbove(high) - firstAbove(low), 0)
        }
    }

    /// For `points` in ascending order, whether the note as of each can be rebuilt.
    func isComplete(at points: [RevisionName]) -> [Bool] {
        var byDevice: [DeviceID: [RevisionName]] = [:]
        for n in listed { byDevice[n.device, default: []].append(n) }
        var devices = covered.entries.map { device, all in
            (device, Device(all: all, have: present[device] ?? [], names: byDevice[device] ?? []))
        }
        let unreadableSnapshot = unreadable.contains { $0.kind == .snapshot }
        let firstUnreadable = unreadable.min()
        var before = Included()
        var merged = 0
        return points.map { point in
            while merged < snapshots.count, snapshots[merged].name <= point {
                before = before.union(snapshots[merged].included)
                merged += 1
            }
            if unreadableSnapshot { return false }
            if let firstUnreadable, firstUnreadable <= point { return false }
            for i in devices.indices {
                let known = before.entries[devices[i].0] ?? Included.Entry()
                // Cursors catch up lazily, so stopping at the first gap is fine.
                if !devices[i].1.complete(at: point, known: known, version: merged) { return false }
            }
            return true
        }
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
