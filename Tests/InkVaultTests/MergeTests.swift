import Foundation
import XCTest
@testable import InkVault

final class MergeTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

    // MARK: Scenarios

    func testConcurrentAddsOnTwoDevicesBothAppear() throws {
        var log = LogBuilder()
        let s1 = stroke(), s2 = stroke(), s3 = stroke()
        let base = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let a = log.delta(devA, 100, [.addStroke(page: p1, stroke: s1), .addStroke(page: p1, stroke: s3)])
        let b = log.delta(devB, 100, [.addStroke(page: p1, stroke: s2)])
        let state = try NoteReducer.reconstruct([b, a, base])
        // Insertion order by add stamp: (100, aaaaaaaa) before (100, bbbbbbbb).
        XCTAssertEqual(state.strokeIds, [[s1.id, s3.id, s2.id]])
        XCTAssertEqual(try NoteReducer.reconstruct([a, base, b]), state)
    }

    func testRemoveWinsOverConcurrentReAdd() throws {
        var log = LogBuilder()
        let s = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: s)])
        let rmA = log.delta(devA, 200, [.removeStroke(page: p1, strokeId: s.id)])
        // B, not having seen the remove, re-adds the same stroke later (e.g. undo).
        let reB = log.delta(devB, 300, [.addStroke(page: p1, stroke: s)])
        XCTAssertEqual(try NoteReducer.reconstruct([d1, rmA, reB]).allStrokeIds, [])
        XCTAssertEqual(try NoteReducer.reconstruct([reB, rmA, d1]).allStrokeIds, [])
        // Still removed when a snapshot saw all three.
        let snapAll = try log.snapshot(devC, 400, from: [d1, rmA, reB])
        XCTAssertEqual(try NoteReducer.reconstruct([snapAll, reB, d1]).allStrokeIds, [])
    }

    /// Documents a limit of format.md §5.4 as amended: a tombstone may be
    /// dropped once its add is covered, so a stale re-add of the *same* id
    /// that arrives after such a snapshot resurrects the stroke. Remove-wins
    /// holds for any set of revisions without that snapshot. If the format
    /// owner decides to keep tombstones longer, flip the last assertion.
    func testStaleReAddAfterCoveringSnapshotResurrects() throws {
        var log = LogBuilder()
        let s = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: s)])
        let rmA = log.delta(devA, 200, [.removeStroke(page: p1, strokeId: s.id)])
        let reB = log.delta(devB, 300, [.addStroke(page: p1, stroke: s)])
        let snap = try log.snapshot(devC, 250, from: [d1, rmA])
        guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertNil(state.tombstones, "the add was covered, so no tombstone is written")
        XCTAssertEqual(try NoteReducer.reconstruct([snap, reB]).allStrokeIds, [s.id])
    }

    func testConcurrentSlicingKeepsBothPieceSets() throws {
        var log = LogBuilder()
        let x = stroke()
        let a1 = stroke(parent: x.id), a2 = stroke(parent: x.id)
        let b1 = stroke(parent: x.id), b2 = stroke(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        let state = try NoteReducer.reconstruct([sliceB, d0, sliceA])
        XCTAssertEqual(state.strokeIds, [[a1.id, a2.id, b1.id, b2.id]])
        XCTAssertTrue(state.pages[0].strokes.allSatisfy { $0.parent == x.id })
        XCTAssertNil(state.tombstones)
    }

    func testTombstonePreventsResurrectionAfterOutOfOrderArrival() throws {
        var log = LogBuilder()
        let s = stroke()
        let page = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let add = log.delta(devA, 100, [.addStroke(page: p1, stroke: s)])        // A seq 2
        let remove = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: s.id)])
        // C has received the page and the remove, but not yet the add.
        let snap = try log.snapshot(devC, 300, from: [page, remove])
        guard case .snapshot(let included, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(included.covers(device: devA, seq: 2))
        XCTAssertEqual(state.tombstones, Tombstones(strokes: [s.id]))
        // The add arrives late; the old remove still wins.
        XCTAssertEqual(try NoteReducer.reconstruct([snap, add]).allStrokeIds, [])
        XCTAssertEqual(try NoteReducer.reconstruct([add, page, snap, remove]).allStrokeIds, [])
        // Without the tombstone, the snapshot would resurrect it (guards the test itself).
        var bare = state
        bare.tombstones = nil
        let unsafe = Revision(noteId: testNote, device: devC, seq: snap.seq, hlc: snap.hlc, wall: snap.wall, app: "x",
                              body: .snapshot(included: included, state: bare))
        XCTAssertEqual(try NoteReducer.reconstruct([unsafe, add]).allStrokeIds, [s.id])
        // Once a later snapshot sees the add, the tombstone is dropped and the stroke stays gone.
        let snap2 = try log.snapshot(devA, 400, from: [snap, add])
        guard case .snapshot(let inc2, let state2) = snap2.body else { return XCTFail("not a snapshot") }
        XCTAssertTrue(inc2.covers(device: devA, seq: 2))
        XCTAssertNil(state2.tombstones)
        XCTAssertEqual(try NoteReducer.reconstruct([snap2, snap, add, page, remove]).allStrokeIds, [])
    }

    func testRemovedPageTombstone() throws {
        var log = LogBuilder()
        let addP = log.delta(devA, 0, [.addPage(Page(id: p2, order: "V")), .addStroke(page: p2, stroke: stroke())])
        let rmP = log.delta(devB, 100, [.removePage(pageId: p2)])
        let snap = try log.snapshot(devC, 200, from: [rmP])
        guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(state.tombstones?.pages, [p2])
        XCTAssertEqual(try NoteReducer.reconstruct([addP, snap]).pages, [])
    }

    func testLateDeltaVersusSnapshotClock() throws {
        // The snapshot recorded title set at t=300; a late delta at t=200 loses.
        var log = LogBuilder()
        let t1 = log.delta(devA, 100, [.setMeta(.title("One"))])
        let t3 = log.delta(devA, 300, [.setMeta(.title("Three"))])
        let snap = try log.snapshot(devB, 400, from: [t1, t3])
        guard case .snapshot(_, let st) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(st.clocks?["title"], Stamp(hlc: t3.hlc, device: devA).description)
        let lateOlder = log.delta(devC, 200, [.setMeta(.title("Two"))])
        XCTAssertEqual(try NoteReducer.reconstruct([lateOlder, snap]).meta.title, "Three")

        // The snapshot recorded title set at t=100; a late delta at t=200 (older
        // than the snapshot itself) wins.
        var log2 = LogBuilder()
        let u1 = log2.delta(devA, 100, [.setMeta(.title("One"))])
        let snapB = try log2.snapshot(devB, 400, from: [u1])
        let late = log2.delta(devC, 200, [.setMeta(.title("Two"))])
        XCTAssertEqual(try NoteReducer.reconstruct([snapB, late]).meta.title, "Two")
        XCTAssertEqual(try NoteReducer.reconstruct([late, u1, snapB]).meta.title, "Two")

        // A snapshot without clocks stamps registers with its own (hlc, device).
        guard case .snapshot(let inc, var bare) = snapB.body else { return XCTFail("not a snapshot") }
        bare.clocks = nil
        let legacy = Revision(noteId: testNote, device: devB, seq: snapB.seq, hlc: snapB.hlc, wall: snapB.wall,
                              app: "x", body: .snapshot(included: inc, state: bare))
        XCTAssertEqual(try NoteReducer.reconstruct([legacy, late]).meta.title, "One")
        let newer = log2.delta(devC, 500, [.setMeta(.title("Five"))])
        XCTAssertEqual(try NoteReducer.reconstruct([legacy, late, newer]).meta.title, "Five")
    }

    func testPageReorderLWW() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addPage(Page(id: p2, order: "b"))])
        let moveA = log.delta(devA, 100, [.setPageOrder(pageId: p1, order: "c")])   // p1 after p2
        let moveB = log.delta(devB, 150, [.setPageOrder(pageId: p2, order: "0")])   // p2 first
        let moveC = log.delta(devC, 120, [.setPageOrder(pageId: p1, order: "Z")])   // loses to nothing on p1? 120 > 100
        let state = try NoteReducer.reconstruct([moveA, moveB, moveC, add])
        XCTAssertEqual(state.pages.map(\.id), [p2, p1])
        XCTAssertEqual(state.pages.map(\.order), ["0", "Z"])
        XCTAssertEqual(state.pages[1].orderClock, Stamp(hlc: moveC.hlc, device: devC).description)

        // Equal order keys tie-break on id.
        let tie = log.delta(devA, 200, [.setPageOrder(pageId: p2, order: "Z")])
        XCTAssertEqual(try NoteReducer.reconstruct([add, moveC, tie]).pages.map(\.id), [p1, p2])

        // The recorded orderClock survives a snapshot: a late older move loses, a late newer one wins.
        let snap = try log.snapshot(devB, 300, from: [add, moveA])
        let lateOld = log.delta(devC, 50, [.setPageOrder(pageId: p1, order: "0")])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateOld]).pages.first { $0.id == p1 }?.order, "c")
        let lateNew = log.delta(devC, 250, [.setPageOrder(pageId: p1, order: "0")])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateNew]).pages.first { $0.id == p1 }?.order, "0")
    }

    func testDeleteAndRestoreNote() throws {
        var log = LogBuilder()
        let d0 = log.delta(devA, 0, [.setMeta(.title("x"))])
        let del = log.delta(devA, 100, [.deleteNote])
        XCTAssertTrue(try NoteReducer.reconstruct([d0, del]).deleted)
        let restore = log.delta(devB, 200, [.restoreNote])
        XCTAssertFalse(try NoteReducer.reconstruct([restore, d0, del]).deleted)
        let delAgain = log.delta(devC, 150, [.deleteNote])    // concurrent, older than the restore
        XCTAssertFalse(try NoteReducer.reconstruct([delAgain, restore, d0, del]).deleted)
        let snap = try log.snapshot(devA, 300, from: [d0, del, restore])
        XCTAssertFalse(try NoteReducer.reconstruct([snap, delAgain]).deleted)
        let delLater = log.delta(devC, 400, [.deleteNote])
        XCTAssertTrue(try NoteReducer.reconstruct([snap, delAgain, delLater]).deleted)
    }

    func testCreatedIsEarliestWall() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 500, [.setMeta(.title("x"))])
        let d2 = log.delta(devB, 100, [.setMeta(.favorite(true))])
        XCTAssertEqual(try NoteReducer.reconstruct([d1, d2]).meta.created, d2.wall)
    }

    func testErrors() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [])
        XCTAssertThrowsError(try NoteReducer.reconstruct([])) { XCTAssertEqual($0 as? NoteLogError, .noRevisions) }
        var other = d
        other.noteId = UUID()
        XCTAssertThrowsError(try NoteReducer.reconstruct([d, other]))
        var clash = d
        clash.body = .delta(ops: [.deleteNote])
        XCTAssertThrowsError(try NoteReducer.reconstruct([d, clash])) {
            XCTAssertEqual($0 as? NoteLogError, .conflictingRevisions(device: devA, seq: 1))
        }
        XCTAssertNoThrow(try NoteReducer.reconstruct([d, d]))   // exact duplicates are fine
    }

    func testIncrementalApplyMatchesReconstruct() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: stroke())])
        let d2 = log.delta(devA, 100, [.addStroke(page: p1, stroke: stroke()), .setMeta(.title("t"))])
        let d3 = log.delta(devB, 200, [.setPageOrder(pageId: p1, order: "W")])
        var state = try NoteReducer.reconstruct([d1])
        state = try NoteReducer.apply([d2], to: state, stamp: .zero)
        state = try NoteReducer.apply([d3], to: state, stamp: .zero)
        XCTAssertEqual(state, try NoteReducer.reconstruct([d3, d1, d2]))
        let snap = try log.snapshot(devA, 300, from: [d1])
        XCTAssertThrowsError(try NoteReducer.apply([snap], to: state, stamp: .zero))
    }

    // MARK: Property: order independence (format.md §5.3)

    func testReconstructIsOrderIndependent() throws {
        for seed in UInt64(1)...4 {
            var rng = SplitMix64(seed: seed)
            let revisions = try randomLog(rng: &rng)
            XCTAssertEqual(revisions.filter { $0.kind == .snapshot }.count, 2)
            let reference = try NoteReducer.reconstruct(revisions)
            XCTAssertFalse(reference.pages.isEmpty, "seed \(seed): generator produced an empty note")
            let refJSON = try InkJSON.encoder().encode(reference)
            for i in 0..<50 {
                let shuffled = revisions.shuffled(using: &rng)
                let state = try NoteReducer.reconstruct(shuffled)
                XCTAssertEqual(state, reference, "seed \(seed) permutation \(i)")
                XCTAssertEqual(try InkJSON.encoder().encode(state), refJSON, "seed \(seed) permutation \(i)")
            }
        }
    }

    /// 3 devices, 200 ops (adds, removes, slices, re-adds, meta, page moves,
    /// page removes, delete/restore), 2 snapshots from partial views.
    func randomLog(rng: inout SplitMix64) throws -> [Revision] {
        let devices = [devA, devB, devC]
        var clocks = [HybridClock(), HybridClock(), HybridClock()]
        var seqs = [0, 0, 0]
        var log: [Revision] = []
        var pages: [UUID] = []
        var strokes: [(page: UUID, stroke: Stroke)] = []
        var opCount = 0
        let snapshotAt = [Int.random(in: 30..<100, using: &rng), Int.random(in: 100..<190, using: &rng)]
        var snapshotsDone = 0
        var step: Int64 = 0

        while opCount < 200 {
            step += 1
            let di = Int.random(in: 0..<3, using: &rng)
            let wall = wallAt(baseMillis + step * 1000 + Int64.random(in: -5000...5000, using: &rng))
            var ops: [Op] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) where opCount < 200 {
                opCount += 1
                let r = Double.random(in: 0..<1, using: &rng)
                if pages.isEmpty || r < 0.10 {
                    let p = Page(id: UUID.random(using: &rng), order: ["a", "b", "V", "c0"].randomElement(using: &rng) ?? "a")
                    pages.append(p.id)
                    ops.append(.addPage(p))
                } else if r < 0.40 || strokes.isEmpty {
                    let page = pages.randomElement(using: &rng) ?? pages[0]
                    let s = stroke(UUID.random(using: &rng))
                    strokes.append((page, s))
                    ops.append(.addStroke(page: page, stroke: s))
                } else if r < 0.50 {
                    if Double.random(in: 0..<1, using: &rng) < 0.15 {
                        // Removal of an id whose add nobody ever writes.
                        ops.append(.removeStroke(page: pages[0], strokeId: UUID.random(using: &rng)))
                    } else if let victim = strokes.randomElement(using: &rng) {
                        ops.append(.removeStroke(page: victim.page, strokeId: victim.stroke.id))
                    }
                } else if r < 0.58, let victim = strokes.randomElement(using: &rng) {
                    // Slice: remove + two pieces.
                    ops.append(.removeStroke(page: victim.page, strokeId: victim.stroke.id))
                    for _ in 0..<2 {
                        let piece = stroke(UUID.random(using: &rng), parent: victim.stroke.id)
                        strokes.append((victim.page, piece))
                        ops.append(.addStroke(page: victim.page, stroke: piece))
                    }
                } else if r < 0.63, let again = strokes.randomElement(using: &rng) {
                    ops.append(.addStroke(page: again.page, stroke: again.stroke))   // re-add attempt
                } else if r < 0.78 {
                    let change: MetaChange
                    switch Int.random(in: 0..<6, using: &rng) {
                    case 0: change = .title("t\(Int.random(in: 0..<100, using: &rng))")
                    case 1: change = .tags(["x\(Int.random(in: 0..<5, using: &rng))"])
                    case 2: change = .notebook(Bool.random(using: &rng) ? nil : "nb")
                    case 3: change = .favorite(Bool.random(using: &rng))
                    case 4: change = .paper(Bool.random(using: &rng) ? .ruled : .blank)
                    default: change = .pageSize(Bool.random(using: &rng) ? .a4 : .letter)
                    }
                    ops.append(.setMeta(change))
                } else if r < 0.88, let p = pages.randomElement(using: &rng) {
                    ops.append(.setPageOrder(pageId: p, order: PageOrder.between(nil, ["a", "b", "c"].randomElement(using: &rng))))
                } else if r < 0.92, pages.count > 2, let p = pages.randomElement(using: &rng) {
                    ops.append(.removePage(pageId: p))
                } else {
                    ops.append(Bool.random(using: &rng) ? .deleteNote : .restoreNote)
                }
            }
            seqs[di] += 1
            log.append(Revision(noteId: testNote, device: devices[di], seq: seqs[di], hlc: clocks[di].tick(wall: wall),
                                wall: wall, app: "test/0", body: .delta(ops: ops)))

            if snapshotsDone < 2, opCount >= snapshotAt[snapshotsDone] {
                snapshotsDone += 1
                let si = Int.random(in: 0..<3, using: &rng)
                // A partial view: the writer has received ~70% of the log so far.
                let view = log.filter { _ in Double.random(in: 0..<1, using: &rng) < 0.7 }
                guard !view.isEmpty else { continue }
                seqs[si] += 1
                log.append(try SnapshotBuilder.makeSnapshot(from: view, device: devices[si], seq: seqs[si],
                                                            clock: &clocks[si], wall: wall, app: "test/0"))
            }
        }
        return log
    }
}
