import Foundation
import XCTest
@testable import Sempere

/// Item gestures (`NoteOps` item builders, `ItemFrames`): every edit's ops,
/// applied by the reducer, give the page the builder predicts; moves are one
/// `setItem`, undo of a delete re-adds under new ids with `parent`, copies get
/// new ids on top; hit testing and resizing of rotated frames.
final class ItemOpsTests: XCTestCase {
    let pageID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
    let blob = BlobRef(sha256: String(repeating: "ab", count: 32), size: 1000, type: "image/png")

    func image(_ id: UUID = UUID(), frame: Rect = Rect(x: 10, y: 20, w: 100, h: 50), z: String = "a",
               rotation: Double? = nil) -> Item {
        var item = Item.image(id: id, blob: blob, pixelSize: Size(w: 200, h: 100), frame: frame, z: z)
        item.rotation = rotation
        return item
    }

    func text(_ s: String, z: String = "a") -> Item {
        .text(TextContent(size: 12, color: .black, runs: [TextRun(s)]), frame: Rect(x: 0, y: 0, w: 50, h: 20), z: z)
    }

    /// Reconstructs the page after `edits` (each one delta) on a fresh note.
    func reduced(_ edits: [[Op]]) throws -> Page {
        var log = LogBuilder()
        var revs = [log.delta(devA, 0, NoteOps.newNote(title: "Items", pageId: pageID))]
        for (i, ops) in edits.enumerated() { revs.append(log.delta(devA, Int64(i + 1) * 10, ops)) }
        return try XCTUnwrap(try NoteReducer.reconstruct(revs).pages.first { $0.id == pageID })
    }

    func strip(_ items: [Item]) -> [Item] {
        items.map { var i = $0; i.origin = nil; i.clocks = nil; return i }
    }

    func testAddMoveResizeDeleteMatchTheReducer() throws {
        let empty = Page(id: pageID, order: "a")
        let a = image(), b = text("hello")
        let add = try NoteOps.placeOnTop(a, on: empty)
        let add2 = try NoteOps.placeOnTop(b, on: add.page)
        XCTAssertEqual(add.added, [a.id])
        XCTAssertNotEqual(add.page.items[0].z, "a", "placed on top with a fresh key")
        let move = try XCTUnwrap(NoteOps.setFrame(a.id, to: Rect(x: 40, y: 60, w: 100, h: 50), on: add2.page))
        XCTAssertEqual(move.ops.count, 1)
        guard case .setItem(_, let id, .frame(let f)) = move.ops[0] else { return XCTFail("\(move.ops)") }
        XCTAssertEqual(id, a.id)
        XCTAssertEqual(f, Rect(x: 40, y: 60, w: 100, h: 50))
        let turn = try XCTUnwrap(NoteOps.setRotation(a.id, to: -90, on: move.page))
        let gone = try XCTUnwrap(NoteOps.removeItems([b.id, UUID()], from: turn.page))
        XCTAssertEqual(gone.ops.count, 1)
        let page = try reduced([add.ops, add2.ops, move.ops, turn.ops, gone.ops])
        XCTAssertEqual(strip(page.items), gone.page.items)
        XCTAssertEqual(page.items.first?.rotation, 270)
    }

    func testNoOpGesturesWriteNothing() throws {
        let a = image()
        let page = Page(id: pageID, order: "a", items: [a])
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: 10.0001, y: 20, w: 100, h: 50), on: page),
                     "below the stored precision")
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: 0, y: 0, w: 0, h: 5), on: page))
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: .nan, y: 0, w: 5, h: 5), on: page))
        XCTAssertNil(NoteOps.setFrame(UUID(), to: Rect(x: 0, y: 0, w: 5, h: 5), on: page))
        XCTAssertNil(NoteOps.setRotation(a.id, to: 360, on: page))
        XCTAssertNil(NoteOps.removeItems([UUID()], from: page))
        XCTAssertNil(NoteOps.bringToFront(a.id, on: page), "already on top")
    }

    func testBringToFrontDrawsAboveTheOthersOfItsLayer() throws {
        let a = image(z: "a"), b = image(z: "b"), bg = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 10, h: 10),
                                                                     frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "z")
        let page = Page(id: pageID, order: "a", items: [bg, a, b].sorted(by: Item.drawsBefore))
        let edit = try XCTUnwrap(NoteOps.bringToFront(a.id, on: page))
        XCTAssertEqual(edit.page.items.map(\.id), [bg.id, b.id, a.id])
        let reducedPage = try reduced([try NoteOps.addItems([bg, a, b], to: Page(id: pageID, order: "a")).ops, edit.ops])
        XCTAssertEqual(reducedPage.items.map(\.id), [bg.id, b.id, a.id])
    }

    func testUndoOfDeleteRestoresUnderNewIDsWithParent() throws {
        let a = image(), b = text("x", z: "b")
        let start = try NoteOps.addItems([a, b], to: Page(id: pageID, order: "a"))
        let gone = try XCTUnwrap(NoteOps.removeItems([a.id, b.id], from: start.page))
        var ids = [UUID(), UUID()].makeIterator()
        let back = try NoteOps.restoreItems([a, b], to: gone.page, newID: { ids.next()! })
        XCTAssertEqual(back.page.items.map(\.parent), [a.id, b.id])
        XCTAssertEqual(back.page.items.map(\.z), ["a", "b"], "drawn where they were")
        let page = try reduced([start.ops, gone.ops, back.ops])
        XCTAssertEqual(strip(page.items), back.page.items)
        XCTAssertFalse(page.items.contains { $0.id == a.id }, "the removed id stays removed")
    }

    func testCopiesGetNewIDsOnTopWithoutParentOrRec() throws {
        var a = image(z: "m")
        a.rec = RecordingLink(id: UUID(), at: 3)
        let target = Page(id: pageID, order: "a", items: [image(z: "q")])
        let copy = try NoteOps.copyItems([a, a], to: target, dx: 10, dy: 5)
        XCTAssertEqual(copy.added.count, 2)
        XCTAssertNotEqual(copy.added[0], a.id)
        XCTAssertNotEqual(copy.added[0], copy.added[1])
        let copies = copy.page.items.filter { copy.added.contains($0.id) }
        XCTAssertEqual(copies.map(\.frame.x), [20, 20])
        XCTAssertEqual(copies.map(\.frame.y), [25, 25])
        XCTAssertTrue(copies.allSatisfy { $0.parent == nil && $0.rec == nil && $0.blob == a.blob })
        XCTAssertEqual(copy.page.items.map(\.id).suffix(2), copy.added[...], "on top, in the order given")
        XCTAssertEqual(NoteOps.blobs(of: [a, a, text("t")]), [blob])
    }

    func testAddRejectsInvalidAndDuplicateItems() {
        let a = image()
        let page = Page(id: pageID, order: "a", items: [a])
        XCTAssertThrowsError(try NoteOps.addItems([a], to: page)) { XCTAssertEqual($0 as? ItemEditError, .duplicateID(a.id)) }
        var bad = image()
        bad.frame.w = 0
        XCTAssertThrowsError(try NoteOps.addItems([bad], to: Page(id: pageID, order: "a")))
    }

    // MARK: ItemFrames

    func testHitTestingFollowsRotationAndPrefersContent() {
        let tall = image(frame: Rect(x: 0, y: 0, w: 100, h: 20), rotation: 90)   // spans y -40...60 at x 40...60
        XCTAssertTrue(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 50, y: -30)))
        XCTAssertFalse(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 90, y: 10)))
        XCTAssertTrue(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 62, y: 10), slop: 3))
        let bg = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 10, h: 10), frame: Rect(x: 0, y: 0, w: 200, h: 200),
                              z: "z")
        let low = image(frame: Rect(x: 0, y: 0, w: 30, h: 30), z: "a"), high = image(frame: Rect(x: 10, y: 10, w: 30, h: 30), z: "b")
        let items = [bg, low, high]
        XCTAssertEqual(ItemFrames.item(at: .init(x: 20, y: 20), in: items)?.id, high.id)
        XCTAssertEqual(ItemFrames.item(at: .init(x: 5, y: 5), in: items)?.id, low.id)
        XCTAssertEqual(ItemFrames.item(at: .init(x: 150, y: 150), in: items)?.id, bg.id)
        XCTAssertNil(ItemFrames.item(at: .init(x: 150, y: 150), in: items, includeBackground: false))
    }

    func testBoundsOfARotatedFrame() {
        let b = ItemFrames.bounds(Rect(x: 0, y: 0, w: 100, h: 20), rotation: 90)
        XCTAssertEqual(b.x, 40, accuracy: 1e-9)
        XCTAssertEqual(b.y, -40, accuracy: 1e-9)
        XCTAssertEqual(b.w, 20, accuracy: 1e-9)
        XCTAssertEqual(b.h, 100, accuracy: 1e-9)
    }

    func testResizeKeepsTheOppositeCornerOnThePage() {
        for rotation in [0.0, 30, 90, 215] {
            let frame = Rect(x: 100, y: 100, w: 80, h: 40)
            for corner in ItemFrames.Corner.allCases {
                let fixedBefore = ItemFrames.corners(frame, rotation: rotation)[corner.opposite.rawValue]
                for keep in [false, true] {
                    let r = ItemFrames.resized(frame, rotation: rotation, corner: corner, dx: 13, dy: -7, keepAspect: keep)
                    let fixedAfter = ItemFrames.corners(r, rotation: rotation)[corner.opposite.rawValue]
                    XCTAssertEqual(fixedAfter.x, fixedBefore.x, accuracy: 1e-9, "r\(rotation) \(corner) aspect \(keep)")
                    XCTAssertEqual(fixedAfter.y, fixedBefore.y, accuracy: 1e-9, "r\(rotation) \(corner) aspect \(keep)")
                    if keep { XCTAssertEqual(r.w / r.h, 2, accuracy: 1e-9) }
                }
            }
        }
    }

    func testResizeFollowsTheDragAndHasAFloor() {
        let frame = Rect(x: 0, y: 0, w: 80, h: 40)
        let r = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: 20, dy: 10, keepAspect: false)
        XCTAssertEqual(r, Rect(x: 0, y: 0, w: 100, h: 50))
        let l = ItemFrames.resized(frame, rotation: nil, corner: .topLeft, dx: 20, dy: 10, keepAspect: false)
        XCTAssertEqual(l, Rect(x: 20, y: 10, w: 60, h: 30))
        // Rotated 90°: dragging the bottom-right corner (now at the bottom-left on the page) left widens it.
        let t = ItemFrames.resized(frame, rotation: 90, corner: .bottomRight, dx: -10, dy: 0, keepAspect: false)
        XCTAssertEqual(t.h, 50, accuracy: 1e-9)
        XCTAssertEqual(t.w, 80, accuracy: 1e-9)
        let tiny = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -500, dy: -500, keepAspect: true)
        XCTAssertEqual(tiny.h, 8, accuracy: 1e-9)
        XCTAssertEqual(tiny.w, 16, accuracy: 1e-9)
        // Keeping proportions, a corner dragged inward along one axis only shrinks the item.
        let narrower = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -20, dy: 0, keepAspect: true)
        XCTAssertEqual(narrower, Rect(x: 0, y: 0, w: 60, h: 30))
        let lower = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: 4, dy: 20, keepAspect: true)
        XCTAssertEqual(lower.h, 60, accuracy: 1e-9, "the axis that changed more wins")
        XCTAssertEqual(lower.w, 120, accuracy: 1e-9)
        let flat = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -500, dy: 0, keepAspect: false)
        XCTAssertEqual(flat.w, 8)
        XCTAssertEqual(ItemFrames.moved(frame, dx: 3, dy: -4), Rect(x: 3, y: -4, w: 80, h: 40))
    }
}
