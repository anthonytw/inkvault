import Foundation
import Sempere

/// What the ledger knows about one canvas stroke without converting it:
/// cheap fingerprints taken from the PencilKit stroke (see
/// `CanvasStrokeInfo.init(_: PKStroke)`). Pure values, so the ledger is
/// testable without PencilKit.
struct CanvasStrokeInfo: Hashable, Sendable {
    /// Identity: equal keys mean "the same canvas stroke, unchanged". Built
    /// from ink, colour, transform, path length, creation date, a few control
    /// points, texture seed and mask ranges. Any edit (move, recolour,
    /// partial erase) changes it.
    struct Key: Hashable, Sendable {
        var ink: String
        var values: [Double]
    }

    /// Strokes that share a family (ink, colour, transform, path creation
    /// date) can be pieces of one another.
    struct Family: Hashable, Sendable {
        var ink: String
        var values: [Double]
    }

    /// Axis-aligned bounds in page points.
    struct Bounds: Hashable, Sendable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double

        func contains(_ o: Bounds, slack: Double = 1) -> Bool {
            o.minX >= minX - slack && o.minY >= minY - slack && o.maxX <= maxX + slack && o.maxY <= maxY + slack
        }
    }

    var key: Key
    var family: Family
    /// Control-point count plus first and last location: equal for the pieces
    /// of a masked (pixel-erased) stroke and the stroke they came from.
    var pathSignature: [Double]
    var bounds: Bounds
}

/// The stable-id side table for one page.
///
/// PencilKit strokes are value types with no identity before iPadOS 27, so
/// the ledger keeps, in canvas order, which stored strokes (our ids) each
/// canvas stroke stands for, keyed by `CanvasStrokeInfo.Key`. On every
/// drawing change it matches the new canvas strokes against that table as a
/// multiset, in order: a matched stroke keeps its ids; an unmatched old one
/// was removed; an unmatched new one was added and gets fresh ids.
///
/// A new stroke's `parent` (format.md §5.6) is, in order of preference:
/// 1. the stroke retired under the same key (an undo of an erase, or a redo,
///    brings back identical content). If that stroke's removal has not been
///    written yet, it simply comes back with its old ids; once the removal is
///    on disk it must get new ids (format.md §5.2) and becomes the parent;
/// 2. a stroke removed in the same change with the same path signature and
///    family (PencilKit's pixel eraser keeps the path and adds a mask);
/// 3. a stroke removed in the same change of the same family whose bounds
///    contain the new one (a slice that rewrote the path).
/// A parent that was never written to disk is replaced by its own parent.
///
/// Ops are the net difference between what is on disk (`committed`) and
/// what is live, so a stroke drawn and erased within one autosave pause
/// never reaches the log.
struct StrokeLedger {
    /// One canvas stroke and the stored strokes it stands for (several for a
    /// masked stroke with several visible ranges, none for a fully masked one).
    struct Entry {
        var info: CanvasStrokeInfo
        var strokes: [Stroke]
    }

    /// One canvas stroke as reported by the canvas.
    struct Item {
        var info: CanvasStrokeInfo
        /// Converts the canvas stroke; called only for strokes the ledger has
        /// not seen. Ids of the result are ignored.
        var make: () -> [Stroke]
    }

    /// What one `update` changed.
    struct Change: Equatable {
        var added: [Stroke] = []
        var removed: [Stroke] = []
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    private(set) var entries: [Entry]
    /// Strokes on disk for this page, in their stored order.
    private(set) var committed: [Stroke]
    /// Every id ever written to disk for this page (live or since removed).
    private var written: Set<UUID>
    /// Removed canvas strokes by key, most recent last.
    private var retired: [CanvasStrokeInfo.Key: [[Stroke]]] = [:]

    /// A ledger for a page loaded from disk; `info` fingerprints the canvas
    /// stroke each stored stroke will be shown as.
    init(stored: [Stroke], info: (Stroke) -> CanvasStrokeInfo) {
        entries = stored.map { Entry(info: info($0), strokes: [$0]) }
        committed = stored
        written = Set(stored.map(\.id))
    }

    /// A ledger for a page loaded from disk whose canvas strokes were
    /// prepared elsewhere (`DrawingPreparation`): `infos[i]` fingerprints the
    /// canvas stroke shown for `stored[i]`. Nil when the counts differ.
    init?(stored: [Stroke], infos: [CanvasStrokeInfo]) {
        guard stored.count == infos.count else { return nil }
        entries = zip(infos, stored).map { Entry(info: $0, strokes: [$1]) }
        committed = stored
        written = Set(stored.map(\.id))
    }

    /// Live strokes, in canvas order.
    var live: [Stroke] { entries.flatMap(\.strokes) }

    /// Re-keys the table for a canvas rebuilt from `live` (one canvas stroke
    /// per stored stroke), keeping ids, history and what is committed.
    mutating func rebase(info: (Stroke) -> CanvasStrokeInfo) {
        entries = live.map { Entry(info: info($0), strokes: [$0]) }
    }

    /// `rebase(info:)` with fingerprints prepared elsewhere: `infos[i]` is
    /// the canvas stroke shown for `live[i]`. False (and nothing changes)
    /// when the counts differ.
    @discardableResult
    mutating func rebase(infos: [CanvasStrokeInfo]) -> Bool {
        let live = self.live
        guard live.count == infos.count else { return false }
        entries = zip(infos, live).map { Entry(info: $0, strokes: [$1]) }
        return true
    }

    /// Matches the canvas's strokes against the table and assigns ids.
    @discardableResult
    mutating func update(_ items: [Item]) -> Change {
        var pool: [CanvasStrokeInfo.Key: [Int]] = [:]
        for (i, e) in entries.enumerated() { pool[e.info.key, default: []].append(i) }
        var keptIndex: [Int?] = []   // per item: matched old entry index
        var used = Set<Int>()
        for item in items {
            if var queue = pool[item.info.key], !queue.isEmpty {
                let i = queue.removeFirst()
                pool[item.info.key] = queue
                used.insert(i)
                keptIndex.append(i)
            } else {
                keptIndex.append(nil)
            }
        }
        var change = Change()
        var removedEntries: [Entry] = []
        for (i, e) in entries.enumerated() where !used.contains(i) {
            removedEntries.append(e)
            change.removed += e.strokes
        }
        for e in removedEntries { retired[e.info.key, default: []].append(e.strokes) }

        var next: [Entry] = []
        for (item, kept) in zip(items, keptIndex) {
            if let kept {
                next.append(entries[kept])
                continue
            }
            if let revived = revive(item.info.key) {
                change.added += revived
                next.append(Entry(info: item.info, strokes: revived))
                continue
            }
            let parents = parentCandidates(for: item.info, removed: removedEntries)
            var strokes = item.make()
            for k in strokes.indices {
                strokes[k].id = UUID()
                strokes[k].origin = nil
                strokes[k].parent = resolveParent(choose(parents, for: strokes[k], index: k))
            }
            change.added += strokes
            next.append(Entry(info: item.info, strokes: strokes))
        }
        entries = next
        return change
    }

    /// The ops that bring the disk up to `live`: removals, then additions in
    /// canvas order.
    func pendingOps(page: UUID, live: [Stroke]) -> [Op] {
        let liveIDs = Set(live.map(\.id))
        let committedIDs = Set(committed.map(\.id))
        let removes = committed.filter { !liveIDs.contains($0.id) }.map { Op.removeStroke(page: page, strokeId: $0.id) }
        let adds = live.filter { !committedIDs.contains($0.id) }.map { Op.addStroke(page: page, stroke: $0) }
        return removes + adds
    }

    /// A save in flight (`beginSave`): the ops it writes and what was on
    /// disk before it.
    struct Save: Equatable {
        var ops: [Op]
        fileprivate var previous: [Stroke]
    }

    /// Starts writing the live strokes: returns the ops that bring the disk up
    /// to them and records them as committed at once, before the write
    /// finishes. Committing late would let an undo during the write revive an
    /// id whose removal is being written, and the next save would add that
    /// removed id again (format.md §5.2), so the stroke would vanish on disk.
    /// Nil when nothing is pending. Call `saveFailed(_:)` if the write fails.
    mutating func beginSave(page: UUID) -> Save? {
        let live = self.live
        let ops = pendingOps(page: page, live: live)
        guard !ops.isEmpty else { return nil }
        let save = Save(ops: ops, previous: committed)
        commit(live)
        return save
    }

    /// The write started by `save` failed: its ops stay pending. Ids it added
    /// stay marked as written (the file may have landed), so they are never
    /// revived after a removal; at worst a later stroke names one as `parent`.
    mutating func saveFailed(_ save: Save) {
        committed = save.previous
    }

    /// Records that `live` (as passed to `pendingOps`) is now on disk.
    mutating func commit(_ live: [Stroke]) {
        let liveIDs = Set(live.map(\.id))
        var kept = committed.filter { liveIDs.contains($0.id) }
        let have = Set(kept.map(\.id))
        kept += live.filter { !have.contains($0.id) }
        committed = kept
        written.formUnion(liveIDs)
    }

    // MARK: - Parents

    private mutating func parentCandidates(for info: CanvasStrokeInfo, removed: [Entry]) -> [Stroke] {
        if var stack = retired[info.key], let last = stack.popLast() {
            retired[info.key] = stack
            return last
        }
        if let e = removed.first(where: { $0.info.family == info.family && $0.info.pathSignature == info.pathSignature }) {
            return e.strokes
        }
        if let e = removed.first(where: { $0.info.family == info.family && $0.info.bounds.contains(info.bounds) }) {
            return e.strokes
        }
        return []
    }

    /// Identical content coming back (undo, redo) keeps its old ids when none
    /// of them has been removed on disk yet: either still committed, or never
    /// written. Otherwise nil, and the stroke gets new ids (format.md §5.2).
    private mutating func revive(_ key: CanvasStrokeInfo.Key) -> [Stroke]? {
        guard var stack = retired[key], let last = stack.last else { return nil }
        let onDisk = Set(committed.map(\.id))
        guard last.allSatisfy({ onDisk.contains($0.id) || !written.contains($0.id) }) else { return nil }
        stack.removeLast()
        retired[key] = stack
        return last
    }

    /// Of several candidate parents, the one nearest the piece's first point.
    private func choose(_ candidates: [Stroke], for piece: Stroke, index: Int) -> Stroke? {
        guard candidates.count > 1, let start = piece.points.first else { return candidates.first }
        func distance(_ s: Stroke) -> Double {
            s.points.map { ($0.x - start.x) * ($0.x - start.x) + ($0.y - start.y) * ($0.y - start.y) }.min() ?? .infinity
        }
        return candidates.min { distance($0) < distance($1) }
    }

    /// A parent that never reached disk is replaced by its own parent.
    private func resolveParent(_ p: Stroke?) -> UUID? {
        guard let p else { return nil }
        return written.contains(p.id) ? p.id : p.parent
    }
}
