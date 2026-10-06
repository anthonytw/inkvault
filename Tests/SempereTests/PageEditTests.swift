import Foundation
import XCTest
@testable import Sempere

/// Page gestures and the paged/pageless switch (format.md §5.4.3): the ops,
/// and that the pages they predict are what a reader reconstructs.
final class PageEditTests: XCTestCase {
    private func ink(_ y: Double, x: Double = 10, transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
               points: [StrokePoint(x: x, y: y - 5, w: 2, h: 2), StrokePoint(x: x + 50, y: y + 5, w: 2, h: 2)],
               transform: transform)
    }

    /// A log that creates `pages` (in order, with their strokes) and `size`.
    private func base(_ log: inout LogBuilder, _ pages: [Page], size: PageSize = .letter) -> Revision {
        var ops: [Op] = [.setMeta(.pageSize(size))]
        for p in pages {
            ops.append(.addPage(Page(id: p.id, order: p.order)))
            ops += p.strokes.map { .addStroke(page: p.id, stroke: $0) }
            if let r = p.recognition { ops.append(.setPageRecognition(pageId: p.id, recognition: r)) }
            if let paper = p.paper { ops.append(.setPagePaper(pageId: p.id, paper: paper)) }
        }
        return log.delta(devA, 0, ops)
    }

    /// The reconstructed pages match the prediction: ids, order keys, stroke ids, recognition, paper.
    private func assertMatches(_ state: NoteState, _ pages: [Page], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.pages.map(\.id), pages.map(\.id), file: file, line: line)
        XCTAssertEqual(state.pages.map(\.order), pages.map(\.order), file: file, line: line)
        XCTAssertEqual(state.strokeIds, pages.map { $0.strokes.map(\.id) }, file: file, line: line)
        XCTAssertEqual(state.pages.map(\.recognition), pages.map(\.recognition), file: file, line: line)
        XCTAssertEqual(state.pages.map(\.paper), pages.map(\.paper), file: file, line: line)
    }

    private func three() -> [Page] {
        [Page(order: "V", strokes: [ink(100)]), Page(order: "k", strokes: [ink(200)]), Page(order: "s")]
    }

    // MARK: Gestures

    func testAddPageAfterCurrentAndAtEnd() throws {
        var log = LogBuilder()
        let pages = three()
        let d0 = base(&log, pages)
        let after = NoteOps.addPage(at: 1, in: pages)
        XCTAssertEqual(after.ops.count, 1)
        guard case .addPage(let added) = after.ops[0] else { return XCTFail("\(after.ops)") }
        XCTAssertTrue(added.strokes.isEmpty)
        XCTAssertEqual(after.pages.map(\.id), [pages[0].id, added.id, pages[1].id, pages[2].id])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, after.ops)]), after.pages)

        let end = NoteOps.addPage(at: 99, in: after.pages)
        XCTAssertEqual(end.pages.last?.id, end.ops.first.flatMap { if case .addPage(let p) = $0 { p.id } else { nil } })
    }

    func testMovePageIsOneSetPageOrder() throws {
        var log = LogBuilder()
        let pages = three()
        let d0 = base(&log, pages)
        let edit = try XCTUnwrap(NoteOps.movePage(pages[2].id, to: 0, in: pages))
        XCTAssertEqual(edit.ops.count, 1)
        XCTAssertEqual(edit.pages.map(\.id), [pages[2].id, pages[0].id, pages[1].id])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, edit.ops)]), edit.pages)
        XCTAssertNil(NoteOps.movePage(pages[1].id, to: 1, in: pages), "not moving writes nothing")
        XCTAssertNil(NoteOps.movePage(UUID(), to: 0, in: pages))
    }

    /// Two devices inserted at the same place and got the same key: there is
    /// no key between them, so the writer re-keys the following page.
    func testMoveBetweenEqualKeysRekeys() throws {
        var log = LogBuilder()
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let pages = [Page(id: a, order: "V"), Page(id: b, order: "V"), Page(order: "k")]
        let d0 = base(&log, pages)
        let edit = try XCTUnwrap(NoteOps.movePage(pages[2].id, to: 1, in: pages))
        XCTAssertEqual(edit.pages.map(\.id), [a, pages[2].id, b])
        XCTAssertEqual(edit.ops.count, 2)
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, edit.ops)]), edit.pages)
    }

    func testDeleteAndUndoRecreatesThePage() throws {
        var log = LogBuilder()
        var pages = three()
        pages[1].recognition = Recognition(engine: "t", text: "hello", words: [])
        pages[1].paper = Paper(kind: .grid)
        let d0 = base(&log, pages)
        let del = try XCTUnwrap(NoteOps.deletePage(pages[1].id, in: pages))
        XCTAssertEqual(del.ops, [.removePage(pageId: pages[1].id)])
        let d1 = log.delta(devA, 10, del.ops)
        let after = try NoteReducer.reconstruct([d0, d1])
        assertMatches(after, del.pages)

        let undo = NoteOps.restorePage(pages[1], at: 1, in: del.pages)
        let restored = undo.pages[1]
        XCTAssertNotEqual(restored.id, pages[1].id)
        XCTAssertEqual(restored.parent, pages[1].id)
        XCTAssertEqual(restored.strokes.map(\.parent), pages[1].strokes.map(\.id))
        XCTAssertEqual(restored.strokes.map(\.points), pages[1].strokes.map(\.points))
        let state = try NoteReducer.reconstruct([d0, d1, log.delta(devA, 20, undo.ops)])
        assertMatches(state, undo.pages)
        XCTAssertEqual(state.pages[1].parent, pages[1].id)
    }

    func testDuplicateGoesRightAfterWithFreshIds() throws {
        var log = LogBuilder()
        var pages = three()
        pages[0].paper = Paper(kind: .dot)
        let d0 = base(&log, pages)
        let dup = try XCTUnwrap(NoteOps.duplicatePage(pages[0].id, in: pages))
        XCTAssertEqual(dup.pages.count, 4)
        XCTAssertEqual(dup.pages[0].id, pages[0].id)
        let copy = dup.pages[1]
        XCTAssertNil(copy.parent)
        XCTAssertEqual(copy.paper, Paper(kind: .dot))
        XCTAssertEqual(copy.strokes.map(\.points), pages[0].strokes.map(\.points))
        XCTAssertTrue(Set(copy.strokes.map(\.id)).isDisjoint(with: pages[0].strokes.map(\.id)))
        XCTAssertEqual(copy.strokes.map(\.parent), [nil])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, dup.ops)]), dup.pages)
    }

    // MARK: Paged and pageless

    func testSheetHeight() {
        XCTAssertEqual(PageSize.letter.sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 612, height: 5000, infinite: true).sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 595, height: 5000, infinite: true, breakHeight: 842).sheetHeight, 842)
        XCTAssertEqual(PageSize(width: 612, height: .nan).sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 612, height: 10, infinite: true, breakHeight: 1).sheetHeight, 72)
        XCTAssertEqual(PageSize(width: 612, height: 10, infinite: true, breakHeight: 1e12).sheetHeight, 200_000)
    }

    /// The position of a stroke in the reading flow: its sheet's top plus its
    /// transformed y, which a switch must never change.
    private func flow(_ pages: [Page], sheet h: Double, pageless: Bool) -> [Double] {
        var out: [Double] = []
        for (i, p) in pages.enumerated() {
            for s in p.strokes {
                let t = s.transform ?? .identity
                let ys = s.points.map { t.b * $0.x + t.d * $0.y + t.ty }
                out.append((pageless ? 0 : Double(i) * h) + (ys.min()! + ys.max()!) / 2)
            }
        }
        return out.sorted()
    }

    func testJoinThenSplitPutsEveryStrokeBack() throws {
        var log = LogBuilder()
        let skew = Transform(a: 1, b: 0.1, c: 0, d: 1, tx: 3, ty: 4)
        let pages = [Page(order: "V", strokes: [ink(100), ink(700)]), Page(order: "k"),
                     Page(order: "s", strokes: [ink(50, transform: skew), ink(400)])]
        let d0 = base(&log, pages)
        let before = flow(pages, sheet: 792, pageless: false)

        let join = NoteOps.makePageless(pages: pages, pageSize: .letter)
        XCTAssertEqual(join.pageSize, PageSize(width: 612, height: 3 * 792, infinite: true, breakHeight: 792))
        XCTAssertEqual(join.pages.count, 1)
        XCTAssertEqual(join.ops.filter { if case .removePage = $0 { true } else { false } }.count, 2)
        let d1 = log.delta(devA, 10, join.ops)
        let joined = try NoteReducer.reconstruct([d0, d1])
        assertMatches(joined, join.pages)
        XCTAssertEqual(joined.meta.pageSize, join.pageSize)
        XCTAssertEqual(flow(joined.pages, sheet: 792, pageless: true), before)
        XCTAssertTrue(joined.pages[0].strokes.contains { $0.transform?.b == 0.1 }, "only ty changes")

        let split = NoteOps.makePaged(pages: joined.pages, pageSize: joined.meta.pageSize)
        XCTAssertEqual(split.pageSize, .letter)
        let d2 = log.delta(devA, 20, split.ops)
        let state = try NoteReducer.reconstruct([d0, d1, d2])
        assertMatches(state, split.pages)
        XCTAssertEqual(state.pages.count, 3, "the blank middle page comes back")
        XCTAssertEqual(state.pages.map { $0.strokes.count }, [2, 0, 2])
        let after = flow(state.pages, sheet: 792, pageless: false)
        for (a, b) in zip(after, before) { XCTAssertEqual(a, b, accuracy: 0.001) }
        XCTAssertTrue(NoteOps.makePaged(pages: state.pages, pageSize: state.meta.pageSize).ops.isEmpty)
    }

    func testSplitOfAnImportedPage() throws {
        var log = LogBuilder()
        let h = 800.0
        let words = [("Lecture", 20.0), ("three", 20.0), ("maps", 60.0), ("kernel", 850.0), ("image", 1700.0)]
        let rec = Recognition(engine: "notability-x", text: "Lecture three\nmaps\nkernel image",
                              words: words.map { Recognition.Word(text: $0.0, box: Recognition.Box(x: 0, y: $0.1, w: 10, h: 10)) })
        let page = Page(order: "V", strokes: [ink(100), ink(900), ink(1750), ink(h * 2 + 2)], recognition: rec)
        let size = PageSize(width: 612, height: 2000, infinite: true, breakHeight: h)
        let d0 = base(&log, [page], size: size)
        let split = NoteOps.makePaged(pages: [page], pageSize: size)
        let state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, split.ops)])
        assertMatches(state, split.pages)
        XCTAssertEqual(state.meta.pageSize, PageSize(width: 612, height: h))
        XCTAssertEqual(state.pages.map { $0.strokes.count }, [1, 1, 2])
        XCTAssertEqual(state.pages[0].id, page.id)
        XCTAssertEqual(state.pages.map { $0.recognition?.text }, ["Lecture three\nmaps", "kernel", "image"])
        XCTAssertEqual(state.pages[1].recognition?.words.first?.box.y, 50)
        XCTAssertEqual(state.pages[2].strokes.map(\.parent), page.strokes.suffix(2).map(\.id))
        XCTAssertEqual(state.pages[2].strokes[0].transform?.ty, -1600)
    }

    func testSplitKeepsBlankSheetsAndStoredHeight() throws {
        let page = Page(order: "V", strokes: [ink(100), ink(2500)])
        let edit = NoteOps.makePaged(pages: [page], pageSize: PageSize(width: 612, height: 5000, infinite: true))
        // Sheets of 792: ink on 0 and 3, stored height covers 6 whole sheets.
        XCTAssertEqual(edit.pages.map { $0.strokes.count }, [1, 0, 0, 1, 0, 0])
        // Nothing beyond the ink when there are several pages: the height is the note's.
        let two = NoteOps.makePaged(pages: [page, Page(order: "k")],
                                    pageSize: PageSize(width: 612, height: 5000, infinite: true))
        XCTAssertEqual(two.pages.map { $0.strokes.count }, [1, 0, 0, 1, 0])
    }

    func testSplitBoundsHostileInk() {
        let far = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                         points: [StrokePoint(x: 0, y: 1e300, w: 2, h: 2)])
        let nan = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                         points: [StrokePoint(x: 0, y: .nan, w: 2, h: 2)])
        let edit = NoteOps.makePaged(pages: [Page(order: "V", strokes: [far, nan])],
                                     pageSize: PageSize(width: 612, height: .infinity, infinite: true))
        XCTAssertEqual(edit.pages.count, NoteOps.maxSheetsPerPage)
        XCTAssertEqual(edit.pages[0].strokes.map(\.id), [nan.id])
    }

    /// format.md §5.4.3: a stroke another device adds below the first sheet
    /// while the split is written stays on the page (not lost).
    func testConcurrentInkBelowASplitStays() throws {
        var log = LogBuilder()
        let page = Page(order: "V", strokes: [ink(100), ink(900)])
        let size = PageSize(width: 612, height: 1600, infinite: true, breakHeight: 792)
        let d0 = base(&log, [page], size: size)
        let split = log.delta(devA, 10, NoteOps.makePaged(pages: [page], pageSize: size).ops)
        let late = ink(1000)
        let other = log.delta(devB, 5, [.addStroke(page: page.id, stroke: late)])
        let state = try NoteReducer.reconstruct([other, split, d0])
        XCTAssertTrue(state.pages[0].strokes.contains { $0.id == late.id })
        XCTAssertFalse(state.meta.pageSize.infinite)
    }
}
