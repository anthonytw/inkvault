import Foundation

// MARK: - Merge (docs/format.md §5.2–§5.5)
//
// Reconstruction is collect-then-resolve: every op is first folded into a
// commutative structure (sets for adds/removes, max-by-key registers for LWW
// fields, min-by-key for stroke adds), then the state is built from those.
// Nothing depends on the order revisions or ops are visited in.

/// Full deterministic key of one op: its revision's stamp, then `seq` and
/// position inside the revision (and inside an `addPage`'s stroke list).
struct OpKey: Comparable {
    var stamp: Stamp
    var seq: Int
    var index: Int
    var sub: Int = 0

    /// Key for a value coming from a snapshot: beats any op with the same stamp.
    static func base(_ stamp: Stamp) -> OpKey { OpKey(stamp: stamp, seq: .max, index: .max, sub: .max) }
    /// Key for a register nobody set: loses to every op.
    static let unset = OpKey(stamp: .zero, seq: .min, index: .min, sub: .min)

    static func < (l: OpKey, r: OpKey) -> Bool {
        (l.stamp, l.seq, l.index, l.sub) < (r.stamp, r.seq, r.index, r.sub)
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
    /// Reconstructs a note (format.md §5.3): the snapshot with the greatest
    /// `(hlc, device, seq)`, plus every delta its `included` does not cover.
    ///
    /// The result is identical for any permutation of `revisions`. It carries
    /// what a snapshot needs: `clocks` for every register, `orderClock` on
    /// every page and `tombstones` (nil when empty).
    public static func reconstruct(_ revisions: [Revision]) throws -> NoteState {
        let revs = try canonical(revisions)
        let deltas = revs.filter { $0.kind == .delta }
        guard let newest = newestSnapshot(revs), case .snapshot(let included, let state) = newest.body else {
            return resolve(base: nil, applying: deltas, seen: deltas)
        }
        let uncovered = deltas.filter { !included.covers(device: $0.device, seq: $0.seq) }
        return resolve(base: (state, newest.stamp), applying: uncovered, seen: deltas)
    }

    /// Applies deltas to an existing state, e.g. for live editing. Registers
    /// without a recorded clock in `state` are treated as stamped `stamp`.
    public static func apply(_ deltas: [Revision], to state: NoteState, stamp: Stamp) throws -> NoteState {
        for d in deltas where d.kind != .delta { throw NoteLogError.notADelta(d.name) }
        let revs = try canonical(deltas)
        return resolve(base: (state, stamp), applying: revs, seen: revs)
    }

    /// The snapshot with the greatest `(hlc, device, seq)`, if any.
    public static func newestSnapshot(_ revisions: [Revision]) -> Revision? {
        revisions.filter { $0.kind == .snapshot }.max { $0.name < $1.name }
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

    /// Folds `applying` into `base`. `seen` is every delta the caller holds
    /// (applied or covered), used only to decide which removals still need a
    /// tombstone.
    static func resolve(base: (state: NoteState, stamp: Stamp)?, applying: [Revision], seen: [Revision]) -> NoteState {
        func baseKey(_ field: String) -> OpKey {
            guard let base else { return .unset }
            return .base(base.state.clocks?[field].flatMap(Stamp.init) ?? base.stamp)
        }

        let meta0 = base?.state.meta ?? NoteMeta(created: applying.map(\.wall).min() ?? Date(timeIntervalSince1970: 0))
        var title = Register(value: meta0.title, key: baseKey("title"))
        var tags = Register(value: meta0.tags, key: baseKey("tags"))
        var notebook = Register(value: meta0.notebook, key: baseKey("notebook"))
        var favorite = Register(value: meta0.favorite, key: baseKey("favorite"))
        var paper = Register(value: meta0.paper, key: baseKey("paper"))
        var pageSize = Register(value: meta0.pageSize, key: baseKey("pageSize"))
        var deleted = Register(value: base?.state.deleted ?? false, key: baseKey("deleted"))
        var created = meta0.created

        let basePages = base?.state.pages ?? []
        var order: [UUID: Register<String>] = [:]
        for p in basePages {
            let k: OpKey = .base(p.orderClock.flatMap(Stamp.init) ?? base?.stamp ?? .zero)
            order[p.id, default: Register(value: p.order, key: k)].offer(p.order, k)
        }
        var addedPages = Set<UUID>()
        var removedPages = Set(base?.state.tombstones?.pages ?? [])
        var removedStrokes = Set(base?.state.tombstones?.strokes ?? [])
        var adds: [UUID: (key: OpKey, page: UUID, stroke: Stroke)] = [:]

        func offerOrder(_ id: UUID, _ value: String, _ k: OpKey) {
            order[id, default: Register(value: value, key: k)].offer(value, k)
        }
        func offerAdd(_ page: UUID, _ stroke: Stroke, _ k: OpKey) {
            if let existing = adds[stroke.id], existing.key <= k { return }
            adds[stroke.id] = (k, page, stroke)
        }

        for rev in applying {
            guard case .delta(let ops) = rev.body else { continue }
            created = min(created, rev.wall)
            for (i, op) in ops.enumerated() {
                let k = OpKey(stamp: rev.stamp, seq: rev.seq, index: i)
                switch op {
                case .addStroke(let page, let stroke):
                    offerAdd(page, stroke, k)
                case .removeStroke(_, let id):
                    removedStrokes.insert(id)
                case .addPage(let page):
                    addedPages.insert(page.id)
                    offerOrder(page.id, page.order, k)
                    for (j, s) in page.strokes.enumerated() {
                        offerAdd(page.id, s, OpKey(stamp: rev.stamp, seq: rev.seq, index: i, sub: j + 1))
                    }
                case .removePage(let id):
                    removedPages.insert(id)
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
                case .deleteNote:
                    deleted.offer(true, k)
                case .restoreNote:
                    deleted.offer(false, k)
                }
            }
        }

        // Resolve pages and strokes.
        let basePageIds = Set(basePages.map(\.id))
        let livePages = basePageIds.union(addedPages).subtracting(removedPages)
        var baseStrokeIds = Set<UUID>()
        var strokes: [UUID: [Stroke]] = [:]
        for p in basePages {
            for s in p.strokes { baseStrokeIds.insert(s.id) }
            if livePages.contains(p.id) {
                strokes[p.id, default: []] += p.strokes.filter { !removedStrokes.contains($0.id) }
            }
        }
        let newStrokes = adds.values
            .filter { !baseStrokeIds.contains($0.stroke.id) && !removedStrokes.contains($0.stroke.id) && livePages.contains($0.page) }
            .sorted { $0.key < $1.key }
        for a in newStrokes { strokes[a.page, default: []].append(a.stroke) }

        var pages: [Page] = []
        for id in livePages {
            guard let reg = order[id] else { continue }
            pages.append(Page(id: id, order: reg.value, strokes: strokes[id] ?? [], orderClock: reg.key.stamp.description))
        }
        // Byte-wise (code point) order, not Swift's normalising String `<`.
        pages.sort { l, r in
            if l.order != r.order { return l.order.utf8.lexicographicallyPrecedes(r.order.utf8) }
            return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
        }

        // Tombstones: removals whose add nobody here has seen.
        var seenStrokes = baseStrokeIds
        var seenPages = basePageIds
        for rev in seen {
            guard case .delta(let ops) = rev.body else { continue }
            for op in ops {
                switch op {
                case .addStroke(_, let s): seenStrokes.insert(s.id)
                case .addPage(let p):
                    seenPages.insert(p.id)
                    for s in p.strokes { seenStrokes.insert(s.id) }
                default: break
                }
            }
        }
        let tomb = Tombstones(strokes: sortedIds(removedStrokes.subtracting(seenStrokes)),
                              pages: sortedIds(removedPages.subtracting(seenPages)))

        let meta = NoteMeta(title: title.value, tags: tags.value, notebook: notebook.value, favorite: favorite.value,
                            created: created, paper: paper.value, pageSize: pageSize.value)
        let clocks: [String: String] = [
            "title": title.key.stamp.description,
            "tags": tags.key.stamp.description,
            "notebook": notebook.key.stamp.description,
            "favorite": favorite.key.stamp.description,
            "paper": paper.key.stamp.description,
            "pageSize": pageSize.key.stamp.description,
            "deleted": deleted.key.stamp.description,
        ]
        return NoteState(deleted: deleted.value, meta: meta, pages: pages, clocks: clocks,
                         tombstones: tomb.isEmpty ? nil : tomb)
    }

    private static func sortedIds(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }
}

// MARK: - Snapshots

public enum SnapshotBuilder {
    /// Writes a snapshot reflecting every given revision: `included` is the
    /// newest snapshot's `included` plus the `(device, seq)` of each input and
    /// of the snapshot itself; `state` carries `clocks`, `orderClock` and
    /// `tombstones`. `clock` observes every input first, so the snapshot sorts
    /// after all of them.
    public static func makeSnapshot(from revisions: [Revision], device: DeviceID, seq: Int,
                                    clock: inout HybridClock, wall: Date, app: String) throws -> Revision {
        let revs = try NoteReducer.canonical(revisions)
        let state = try NoteReducer.reconstruct(revs)
        var included = Included()
        if let newest = NoteReducer.newestSnapshot(revs), case .snapshot(let inc, _) = newest.body {
            included = inc
        }
        for r in revs {
            clock.observe(r.hlc, wall: wall)
            included.insert(device: r.device, seq: r.seq)
        }
        included.insert(device: device, seq: seq)
        let hlc = clock.tick(wall: wall)
        return Revision(noteId: revs[0].noteId, device: device, seq: seq, hlc: hlc, wall: wall, app: app,
                        body: .snapshot(included: included, state: state))
    }
}
