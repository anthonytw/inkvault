import Foundation
import XCTest
@testable import Sempere

final class RecognitionSupportTests: VaultTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Recognition.Box { .init(x: x, y: y, w: w, h: h) }
    private func line(_ text: String, _ b: Recognition.Box) -> RecognizedLine {
        RecognizedLine(text: text, words: RecognitionLayout.distribute(text: text, in: b))
    }

    // MARK: basis and policy

    func testDigestIgnoresOrderAndCaseAndChangesWithTheSet() {
        let a = id(1), b = id(2)
        XCTAssertEqual(RecognitionBasis.digest(of: [a, b]), RecognitionBasis.digest(of: [b, a]))
        XCTAssertNotEqual(RecognitionBasis.digest(of: [a, b]), RecognitionBasis.digest(of: [a]))
        XCTAssertNotEqual(RecognitionBasis.digest(of: [a]), RecognitionBasis.digest(of: [b]))
        XCTAssertEqual(RecognitionBasis.digest(of: [a, b]).count, 32)
        // SHA-256("") starts e3b0c442 98fc1c14 9afbf4c8 996fb924.
        XCTAssertEqual(RecognitionBasis.digest(of: [UUID]()), "e3b0c44298fc1c149afbf4c8996fb924")
        // Two ids, as lowercase text joined by a newline.
        XCTAssertEqual(RecognitionBasis.digest(of: [UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!]),
                       RecognitionBasis.digest(of: [UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!]))
    }

    /// format.md §5.5: readers ignore a `basis` they do not understand. A
    /// non-string one must not make the revision unreadable.
    func testABasisThatIsNotAStringIsIgnored() throws {
        for basis in ["5", "{\"v\":2}", "[\"a\"]", "null"] {
            let json = Data(#"{"engine":"x-1","text":"hi","words":[],"basis":\#(basis)}"#.utf8)
            let r = try JSONDecoder().decode(Recognition.self, from: json)
            XCTAssertEqual(r.text, "hi", basis)
            XCTAssertNil(r.basis, basis)
        }
        let json = Data(#"{"engine":"x-1","text":"hi","words":[],"basis":"abc"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Recognition.self, from: json).basis, "abc")
        // Round trip: encoded as before (no basis key when nil).
        let plain = Recognition(engine: "x-1", text: "hi")
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("basis"))
        XCTAssertEqual(try JSONDecoder().decode(Recognition.self, from: Data(encoded.utf8)), plain)
    }

    func testPolicyForOurOwnRecognition() {
        let ids = [id(1), id(2)]
        let current = Recognition(engine: "e", text: "x", basis: RecognitionBasis.digest(of: ids))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(current, strokeIDs: ids))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(current, strokeIDs: ids.reversed()))
        XCTAssertTrue(RecognitionPolicy.needsRecognition(current, strokeIDs: ids + [id(3)]), "a stroke was added")
        XCTAssertTrue(RecognitionPolicy.needsRecognition(current, strokeIDs: [ids[0]]), "a stroke was erased")
        // Recognition without text is still current: a page of doodles is not re-read every time.
        let empty = Recognition(engine: "e", text: "", basis: RecognitionBasis.digest(of: ids))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(empty, strokeIDs: ids))
        // Everything erased: stale until cleared.
        XCTAssertTrue(RecognitionPolicy.needsRecognition(current, strokeIDs: []))
        XCTAssertTrue(RecognitionPolicy.needsRecognition(empty, strokeIDs: []), "its basis names strokes that are gone")
    }

    func testPolicyKeepsImportedRecognitionUnlessStrokesChanged() {
        let ids = [id(1)]
        let imported = Recognition(engine: "notability-14.2.6", text: "Lecture 3")
        XCTAssertFalse(RecognitionPolicy.needsRecognition(imported, strokeIDs: ids))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(imported, strokeIDs: []), "a page without ink keeps its text")
        XCTAssertTrue(RecognitionPolicy.needsRecognition(imported, strokeIDs: ids, touched: true))
        XCTAssertTrue(RecognitionPolicy.needsRecognition(imported, strokeIDs: [], touched: true), "all ink erased")
        XCTAssertFalse(RecognitionPolicy.needsRecognition(Recognition(engine: "n", text: ""), strokeIDs: [], touched: true))
    }

    func testPolicyWithoutRecognition() {
        XCTAssertTrue(RecognitionPolicy.needsRecognition(nil, strokeIDs: [id(1)]))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(nil, strokeIDs: []))
        XCTAssertFalse(RecognitionPolicy.needsRecognition(nil, strokeIDs: [], touched: true))
    }

    func testBasisSurvivesTheVaultAndASnapshot() throws {
        var log = LogBuilder()
        let (page, s1) = (id(10), wireStroke(id(11)))
        var rec = Recognition(engine: "vision-26", text: "hello", words: [.init(text: "hello", box: box(1, 2, 3, 4))])
        rec.basis = RecognitionBasis.digest(of: [s1.id])
        let d1 = log.delta(devA, 0, [.addPage(Page(id: page, order: "a0")), .addStroke(page: page, stroke: s1),
                                     .setPageRecognition(pageId: page, recognition: rec)])
        let snap = try log.snapshot(devB, 50, from: [d1])
        for revisions in [[d1], [d1, snap]] {
            let state = try NoteReducer.reconstruct(revisions)
            XCTAssertEqual(state.pages[0].recognition, rec)
            XCTAssertFalse(RecognitionPolicy.needsRecognition(state.pages[0]))
        }
        // The wire form carries it as "basis", and a reader without it still decodes.
        let json = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        XCTAssertTrue(json.contains("\"basis\":\"\(rec.basis!)\""))
        let old = #"{"engine":"notability-1","text":"hi","words":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Recognition.self, from: Data(old.utf8)).basis)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Recognition(engine: "x", text: "y")), as: UTF8.self)
            .contains("basis"))
    }

    func testSummaryCountsPagesNeedingRecognitionAndKeepsTheirText() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        let (p1, p2, p3) = (id(1), id(2), id(3))
        let (s1, s2) = (wireStroke(id(21)), wireStroke(id(22)))
        let current = Recognition(engine: "vision-26", text: "alpha beta", basis: RecognitionBasis.digest(of: [s1.id]))
        let imported = Recognition(engine: "notability-1", text: "gamma")
        try vault.apply([.setMeta(.title("T")), .addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1),
                         .setPageRecognition(pageId: p1, recognition: current),
                         .addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: s2),   // no recognition
                         .addPage(Page(id: p3, order: "a2")),                                   // blank
                         .setPageRecognition(pageId: p3, recognition: imported)],
                        to: note, deviceState: tmp.appendingPathComponent("d.json"), app: "t")
        let s = try vault.summary(of: note)
        XCTAssertEqual(s.pagesNeedingRecognition, 1)
        XCTAssertEqual(s.recognizedPages, 2)
        XCTAssertEqual(s.pageTexts.map(\.number), [1, 3])
        XCTAssertEqual(s.pageTexts.map(\.text), ["alpha beta", "gamma"])
        XCTAssertEqual(s.pageTexts[0].pageId, p1)
    }

    // MARK: layout

    func testPageBoxFlipsYAndScalesToTheRegion() {
        let r = box(100, 200, 400, 300)
        // A normalised box in the bottom-left quarter of the image.
        let b = RecognitionLayout.pageBox(normalized: box(0, 0, 0.5, 0.5), region: r)
        XCTAssertEqual(b, box(100, 350, 200, 150))
        // Top-right quarter.
        XCTAssertEqual(RecognitionLayout.pageBox(normalized: box(0.5, 0.5, 0.5, 0.5), region: r), box(300, 200, 200, 150))
        // Out of range and non-finite values are clamped into the region.
        let c = RecognitionLayout.pageBox(normalized: box(-1, .nan, 3, 0.5), region: r)
        XCTAssertGreaterThanOrEqual(c.x, 100)
        XCTAssertLessThanOrEqual(c.x + c.w, 500)
        XCTAssertTrue([c.x, c.y, c.w, c.h].allSatisfy(\.isFinite))
    }

    func testDistributeSplitsAtWhitespaceProportionally() {
        let words = RecognitionLayout.distribute(text: "aa  bbbb\nc", in: box(0, 10, 90, 5))
        XCTAssertEqual(words.map(\.text), ["aa", "bbbb", "c"])
        XCTAssertEqual(words.map(\.box.x), [0, 30, 80])    // 9 units of 10 pt (aa␣bbbb␣c)
        XCTAssertEqual(words.map(\.box.w), [20, 40, 10])
        XCTAssertTrue(words.allSatisfy { $0.box.y == 10 && $0.box.h == 5 })
        XCTAssertEqual(RecognitionLayout.distribute(text: "  \n ", in: box(0, 0, 1, 1)), [])
    }

    func testAssembleOrdersRowsTopDownAndLinesLeftToRight() {
        // Given out of order: the second row's line, a right-hand line on row one, the left-hand one.
        let lines = [line("linear maps", box(50, 100, 120, 20)),
                     line("(2026)", box(300, 42, 60, 20)),
                     line("Lecture 3", box(50, 40, 100, 24))]
        let r = RecognitionLayout.assemble(engine: "vision-26", lines: lines, basis: "b")
        XCTAssertEqual(r.text, "Lecture 3 (2026)\nlinear maps")
        XCTAssertEqual(r.words.map(\.text), ["Lecture", "3", "(2026)", "linear", "maps"])
        XCTAssertEqual(r.engine, "vision-26")
        XCTAssertEqual(r.basis, "b")
    }

    func testAssembleDropsEmptyAndBrokenLinesAndFlattensNewlines() {
        let bad = RecognizedLine(text: "x", words: [.init(text: "x", box: box(.nan, 0, 1, 1))])
        let none = RecognizedLine(text: "  ", words: [.init(text: " ", box: box(0, 0, 1, 1))])
        let multi = RecognizedLine(text: "a\nb", words: [.init(text: "a", box: box(0, 0, 5, 5)), .init(text: "b", box: box(6, 0, 5, 5))])
        let r = RecognitionLayout.assemble(engine: "e", lines: [bad, none, multi], basis: nil)
        XCTAssertEqual(r.text, "a b")
        XCTAssertEqual(RecognitionLayout.assemble(engine: "e", lines: [], basis: nil).text, "")
    }

    // MARK: pages a pass reads (`sempere recognize` modes)

    func testPagesToReadPerMode() {
        func stroke(_ n: Int) -> Stroke {
            Stroke(id: id(n), ink: Ink(tool: .pen, color: .black, width: 2), points: [StrokePoint(x: 1, y: 1, t: 0, w: 2, h: 2)])
        }
        func page(_ n: Int, strokes: [Stroke], _ rec: Recognition?) -> Page {
            var p = Page(id: id(100 + n), order: "a\(n)", strokes: strokes)
            p.recognition = rec
            return p
        }
        let ink = [stroke(1), stroke(2)]
        let ours = Recognition(engine: "vision-26.0", text: "x", basis: RecognitionBasis.digest(of: ink.map(\.id)))
        let pages = [
            page(1, strokes: ink, nil),                                                         // never read
            page(2, strokes: ink, ours),                                                        // current
            page(3, strokes: ink + [stroke(3)], ours),                                          // stale: ink added
            page(4, strokes: ink, Recognition(engine: "notability-14", text: "Lecture")),       // Notability's
            page(5, strokes: [], nil),                                                          // blank
            page(6, strokes: [], ours),                                                         // our text, ink erased
            page(7, strokes: [], Recognition(engine: "notability-14", text: "Old")),           // Notability's text, no ink
        ]
        func numbers(_ mode: RecognitionMode) -> [Int] {
            RecognitionPolicy.pagesToRead(pages, mode: mode).compactMap { p in pages.firstIndex(of: p).map { $0 + 1 } }
        }
        XCTAssertEqual(numbers(.stale), [1, 3, 6], "Notability's recognition is never replaced by default")
        XCTAssertEqual(numbers(.missing), [1])
        XCTAssertEqual(numbers(.all), [1, 2, 3, 4, 6, 7])
    }
}
