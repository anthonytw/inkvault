import Foundation

// MARK: - Merge (docs/format.md §5.2–§5.6)
//
// Reconstruction is collect-then-resolve. Every snapshot and every delta not
// covered by any snapshot is folded into commutative structures (removal
// sets, min-origin evidence per page and stroke, max-key LWW registers); the
// state is then built from those. Nothing depends on visiting order, and no
// single snapshot is privileged.

/// Full deterministic LWW key: the stamp, then `seq` and op index inside the
/// revision, then the source revision (which only separates snapshot values
/// that carry the same recorded clock).
struct OpKey: Comparable {
    var stamp: Stamp
    var seq: Int
    var index: Int
    var src: RevisionName

    /// A value held by snapshot `src`, last set at `stamp`: beats any op with the same stamp.
    static func base(_ stamp: Stamp, _ src: RevisionName) -> OpKey {
        OpKey(stamp: stamp, seq: .max, index: .max, src: src)
    }

    /// A register nobody set: loses to everything.
    static let unset = OpKey(stamp: .zero, seq: .min, index: .min,
                             src: RevisionName(hlc: .zero, device: .zero, seq: 0, kind: .delta))

    static func < (l: OpKey, r: OpKey) -> Bool {
        (l.stamp, l.seq, l.index, l.src) < (r.stamp, r.seq, r.index, r.src)
    }
}

/// Last-writer-wins register; commutative, associative, idempotent.
struct Register<Value> {
    var value: Value
    var key: OpKey

    mutating func offer(_ v: Value, _ k: OpKey) {
        if k > key { value = v; key = k }
    }
}

/// Rebuilds note state from revisions.
public enum NoteReducer {
    /// Reconstructs a note (format.md §5.3): the merge of every snapshot plus
    /// every delta no snapshot's `included` covers.
    ///
    /// The result is identical for any permutation of `revisions`. It carries
    /// what a snapshot needs: all `clocks`, `orderClock` and `origin` on every
    /// page, `origin` on every stroke, and `tombstones` (nil when empty).
    public static func reconstruct(_ revisions: [Revision]) throws -> NoteState {
        try resolve(canonical(revisions)).state
    }

    /// Applies deltas to an existing state, e.g. for live editing. `state`
    /// acts as a snapshot that covers nothing; registers without a recorded
    /// clock are treated as stamped `stamp`.
    public static func apply(_ deltas: [Revision], to state: NoteState, stamp: Stamp) throws -> NoteState {
        for d in deltas where d.kind != .delta { throw NoteLogError.notADelta(d.name) }
        let revs = try canonical(deltas)
        let base = Snap(name: RevisionName(hlc: stamp.hlc, device: stamp.device, seq: 0, kind: .snapshot),
                        included: Included(), state: state)
        let earliest = revs.min { $0.name < $1.name }?.wall
        return resolve(snapshots: [base], deltas: revs, earliestWall: earliest).state
    }

    /// Checks one note id, drops exact duplicates, rejects two different
    /// revisions with the same `(device, seq)`.
    static func canonical(_ revisions: [Revision]) throws -> [Revision] {
        guard let first = revisions.first else { throw NoteLogError.noRevisions }
        var byKey: [DeviceID: [Int: Revision]] = [:]
        for r in revisions {
            guard r.noteId == first.noteId else { throw NoteLogError.mixedNotes(first.noteId, r.noteId) }
            if let existing = byKey[r.device]?[r.seq] {
                guard existing == r else { throw NoteLogError.conflictingRevisions(device: r.device, seq: r.seq) }
            } else {
                byKey[r.device, default: [:]][r.seq] = r
            }
        }
        return byKey.values.flatMap(\.values)
    }

    struct Snap {
        var name: RevisionName
        var included: Included
        var state: NoteState
    }

    struct Resolution {
        var state: NoteState
        /// Everything the state reflects in full: every snapshot's `included`,
        /// the snapshots themselves, and every applied delta that is not an orphan.
        var included: Included
    }

    static func resolve(_ revs: [Revision]) -> Resolution {
        var snaps: [Snap] = []
        var deltas: [Revision] = []
        for r in revs {
            switch r.body {
            case .delta: deltas.append(r)
            case .snapshot(let included, let state): snaps.append(Snap(name: r.name, included: included, state: state))
            }
        }
        let earliest = revs.min { $0.name < $1.name }?.wall
        return resolve(snapshots: snaps, deltas: deltas, earliestWall: earliest)
    }

    /// Item evidence: where a page or stroke was seen and which op added it.
    struct Evidence<Item> {
        var origin: Origin
        var src: RevisionName
        var item: Item
        var page: UUID?

        func beats(_ other: Evidence) -> Bool { (origin, src) < (other.origin, other.src) }
    }

    static func resolve(snapshots: [Snap], deltas: [Revision], earliestWall: Date?) -> Resolution {
        let uncovered = deltas.filter { d in !snapshots.contains { $0.included.covers(device: d.device, seq: d.seq) } }

        // Removals: every snapshot's tombstones plus removes in uncovered deltas.
        var removedPages = Set<UUID>()
        var removedStrokes = Set<UUID>()
        for s in snapshots {
            removedPages.formUnion(s.state.tombstones?.pages ?? [])
            removedStrokes.formUnion(s.state.tombstones?.strokes ?? [])
        }
        for d in uncovered {
            for op in d.ops {
                switch op {
                case .removePage(let id): removedPages.insert(id)
                case .removeStroke(_, let id): removedStrokes.insert(id)
                default: break
                }
            }
        }

        // Orphans (§5.3): a delta whose page-targeting op names a page nobody
        // has seen is applied but not listed in `included`, so it is applied
        // again once the page arrives.
        var knownPages = removedPages
        for s in snapshots { knownPages.formUnion(s.state.pages.map(\.id)) }
        for d in deltas {
            for case .addPage(let p) in d.ops { knownPages.insert(p.id) }
        }
        func isOrphan(_ d: Revision) -> Bool {
            d.ops.contains { op in
                switch op {
                case .addStroke(let page, _): return !knownPages.contains(page)
                case .setPageOrder(let page, _): return !knownPages.contains(page)
                default: return false
                }
            }
        }
        let orphans = Set(uncovered.filter(isOrphan).map(\.name))

        // LWW registers.
        let defaults = NoteMeta(created: Date(timeIntervalSince1970: 0))
        var title = Register(value: defaults.title, key: .unset)
        var tags = Register(value: defaults.tags, key: .unset)
        var notebook = Register(value: defaults.notebook, key: .unset)
        var favorite = Register(value: defaults.favorite, key: .unset)
        var paper = Register(value: defaults.paper, key: .unset)
        var pageSize = Register(value: defaults.pageSize, key: .unset)
        var deleted = Register(value: false, key: .unset)
        var created = earliestWall
        var order: [UUID: Register<String>] = [:]
        var pages: [UUID: Evidence<Page>] = [:]
        var strokes: [UUID: Evidence<Stroke>] = [:]
        var snapPageIds: [RevisionName: Set<UUID>] = [:]
        var snapStrokeIds: [RevisionName: Set<UUID>] = [:]

        func offerOrder(_ id: UUID, _ value: String, _ k: OpKey) {
            order[id, default: Register(value: value, key: k)].offer(value, k)
        }
        func offerPage(_ e: Evidence<Page>) {
            if let cur = pages[e.item.id], !e.beats(cur) { return }
            pages[e.item.id] = e
        }
        func offerStroke(_ e: Evidence<Stroke>) {
            if let cur = strokes[e.item.id], !e.beats(cur) { return }
            strokes[e.item.id] = e
        }

        for s in snapshots {
            let stamp = s.name.stamp
            func key(_ field: String) -> OpKey { .base(s.state.clocks?[field].flatMap(Stamp.init) ?? stamp, s.name) }
            let m = s.state.meta
            title.offer(m.title, key("title"))
            tags.offer(m.tags, key("tags"))
            notebook.offer(m.notebook, key("notebook"))
            favorite.offer(m.favorite, key("favorite"))
            paper.offer(m.paper, key("paper"))
            pageSize.offer(m.pageSize, key("pageSize"))
            deleted.offer(s.state.deleted, key("deleted"))
            created = min(created ?? m.created, m.created)

            var pageIds = Set<UUID>(), strokeIds = Set<UUID>()
            for (pos, p) in s.state.pages.enumerated() {
                pageIds.insert(p.id)
                // Without a recorded origin, the holding snapshot is the origin (§5.5).
                let origin = p.origin.flatMap(Origin.init) ?? Origin(s.name, op: pos)
                offerPage(Evidence(origin: origin, src: s.name, item: p, page: nil))
                offerOrder(p.id, p.order, .base(p.orderClock.flatMap(Stamp.init) ?? stamp, s.name))
                for (j, st) in p.strokes.enumerated() {
                    strokeIds.insert(st.id)
                    let so = st.origin.flatMap(Origin.init) ?? Origin(s.name, op: j)
                    offerStroke(Evidence(origin: so, src: s.name, item: st, page: p.id))
                }
            }
            snapPageIds[s.name] = pageIds
            snapStrokeIds[s.name] = strokeIds
        }

        for d in uncovered {
            for (i, op) in d.ops.enumerated() {
                let k = OpKey(stamp: d.stamp, seq: d.seq, index: i, src: d.name)
                switch op {
                case .addStroke(let page, let stroke):
                    offerStroke(Evidence(origin: Origin(d.name, op: i), src: d.name, item: stroke, page: page))
                case .addPage(let page):
                    // §5.2: the page is added empty.
                    offerPage(Evidence(origin: Origin(d.name, op: i), src: d.name, item: page, page: nil))
                    offerOrder(page.id, page.order, k)
                case .setPageOrder(let id, let value):
                    offerOrder(id, value, k)
                case .setMeta(let change):
                    switch change {
                    case .title(let v): title.offer(v, k)
                    case .tags(let v): tags.offer(v, k)
                    case .notebook(let v): notebook.offer(v, k)
                    case .favorite(let v): favorite.offer(v, k)
                    case .paper(let v): paper.offer(v, k)
                    case .pageSize(let v): pageSize.offer(v, k)
                    }
                case .deleteNote: deleted.offer(true, k)
                case .restoreNote: deleted.offer(false, k)
                case .removeStroke, .removePage: break
                }
            }
        }

        // An item is gone if a snapshot covers the revision that added it but
        // does not contain it: that snapshot saw the add and later the removal.
        func removedByCoverage(_ origin: Origin, _ id: UUID, _ held: [RevisionName: Set<UUID>]) -> Bool {
            snapshots.contains { s in
                s.included.covers(device: origin.device, seq: origin.seq) && !(held[s.name]?.contains(id) ?? false)
            }
        }

        let livePages = Set(pages.values.filter { e in
            !removedPages.contains(e.item.id) && !removedByCoverage(e.origin, e.item.id, snapPageIds)
        }.map(\.item.id))

        var byPage: [UUID: [Evidence<Stroke>]] = [:]
        for e in strokes.values {
            guard let page = e.page, livePages.contains(page), !removedStrokes.contains(e.item.id),
                  !removedByCoverage(e.origin, e.item.id, snapStrokeIds) else { continue }
            byPage[page, default: []].append(e)
        }

        var outPages: [Page] = []
        for id in livePages {
            guard let e = pages[id], let reg = order[id] else { continue }
            let list = (byPage[id] ?? []).sorted { ($0.origin, $0.item.id.uuidString) < ($1.origin, $1.item.id.uuidString) }
            outPages.append(Page(id: id, order: reg.value,
                                 strokes: list.map { var s = $0.item; s.origin = $0.origin.description; return s },
                                 orderClock: reg.key.stamp.description, origin: e.origin.description))
        }
        // Byte-wise (code point) order, not Swift's normalising String `<`.
        outPages.sort { l, r in
            if l.order != r.order { return l.order.utf8.lexicographicallyPrecedes(r.order.utf8) }
            return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
        }

        // What the new `included` will reflect, and tombstones for removals
        // whose add it does not reflect.
        var included = Included()
        var seenPages = Set<UUID>(), seenStrokes = Set<UUID>()
        for s in snapshots {
            included = included.union(s.included)
            if s.name.seq >= 1 { included.insert(device: s.name.device, seq: s.name.seq) }
            seenPages.formUnion(snapPageIds[s.name] ?? [])
            seenStrokes.formUnion(snapStrokeIds[s.name] ?? [])
        }
        for d in uncovered where !orphans.contains(d.name) {
            included.insert(device: d.device, seq: d.seq)
        }
        for d in deltas where included.covers(device: d.device, seq: d.seq) {
            for op in d.ops {
                switch op {
                case .addPage(let p): seenPages.insert(p.id)
                case .addStroke(_, let s): seenStrokes.insert(s.id)
                default: break
                }
            }
        }
        let tomb = Tombstones(strokes: sortedIds(removedStrokes.subtracting(seenStrokes)),
                              pages: sortedIds(removedPages.subtracting(seenPages)))

        let meta = NoteMeta(title: title.value, tags: tags.value, notebook: notebook.value, favorite: favorite.value,
                            created: created ?? defaults.created, paper: paper.value, pageSize: pageSize.value)
        let clocks: [String: String] = [
            "title": title.key.stamp.description,
            "tags": tags.key.stamp.description,
            "notebook": notebook.key.stamp.description,
            "favorite": favorite.key.stamp.description,
            "paper": paper.key.stamp.description,
            "pageSize": pageSize.key.stamp.description,
            "deleted": deleted.key.stamp.description,
        ]
        let state = NoteState(deleted: deleted.value, meta: meta, pages: outPages, clocks: clocks,
                              tombstones: tomb.isEmpty ? nil : tomb)
        return Resolution(state: state, included: included)
    }

    private static func sortedIds(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }
}

extension Revision {
    /// The ops of a delta; empty for a snapshot.
    var ops: [Op] {
        if case .delta(let ops) = body { return ops }
        return []
    }
}

// MARK: - Snapshots

public enum SnapshotBuilder {
    /// Writes a snapshot of every given revision. `included` lists only what
    /// the state reflects in full (§5.3): every input snapshot's `included`,
    /// the input snapshots, every applied delta except orphans, and the new
    /// snapshot itself. `clock` observes every input first, so the snapshot
    /// sorts after all of them.
    public static func makeSnapshot(from revisions: [Revision], device: DeviceID, seq: Int,
                                    clock: inout HybridClock, wall: Date, app: String) throws -> Revision {
        let revs = try NoteReducer.canonical(revisions)
        let res = NoteReducer.resolve(revs)
        for r in revs { clock.observe(r.hlc, wall: wall) }
        var included = res.included
        included.insert(device: device, seq: seq)
        let hlc = clock.tick(wall: wall)
        return Revision(noteId: revs[0].noteId, device: device, seq: seq, hlc: hlc, wall: wall, app: app,
                        body: .snapshot(included: included, state: res.state))
    }
}
