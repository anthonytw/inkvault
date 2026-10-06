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
}

final class RecognitionRunTests: VaultTestCase {
    var stateURL: URL { tmp.appendingPathComponent("device.json") }

    private func note(_ vault: Vault, title: String, strokes: Int, pages: Int = 1) throws -> UUID {
        let id = UUID()
        let first = UUID()
        var ops = NoteOps.newNote(title: title, pageId: first)
        for n in 1..<max(pages, 1) { ops.append(.addPage(Page(id: UUID(), order: PageOrder.between(PageOrder.between(nil, nil), nil)))); _ = n }
        for _ in 0..<strokes { ops.append(.addStroke(page: first, stroke: stroke())) }
        try vault.apply(ops, to: id, deviceState: stateURL, app: "test")
        return id
    }

    private func fake(_ text: String) -> (Page) throws -> Recognition {
        { page in
            Recognition(engine: "fake-1", text: text,
                        words: RecognitionLayout.distribute(text: text, in: .init(x: 0, y: 0, w: 100, h: 10)))
        }
    }

    func testRecognizesPagesAndReportsTheNote() throws {
        let vault = try makeVault(pqIdentity())
        let id = try note(vault, title: "Lecture", strokes: 2, pages: 2)
        let report = try XCTUnwrap(try vault.recognizeNote(id, deviceState: stateURL, app: "test", recognize: fake("hello wombat")))
        XCTAssertEqual(report.id, id)
        XCTAssertEqual(report.title, "Lecture")
        XCTAssertEqual(report.pages, 2)
        XCTAssertEqual(report.pagesRecognized, 1, "the second page has no strokes and nothing to clear")
        let state = try vault.reconstruct(noteId: id)
        let recognition = try XCTUnwrap(state.pages[0].recognition)
        XCTAssertEqual(recognition.text, "hello wombat")
        XCTAssertEqual(recognition.basis, RecognitionBasis.digest(of: state.pages[0]))
        XCTAssertEqual(try vault.summary(of: id).pagesNeedingRecognition, 0)
    }

    func testNothingToDoWritesNoDelta() throws {
        let vault = try makeVault(pqIdentity())
        let id = try note(vault, title: "T", strokes: 1)
        try vault.recognizeNote(id, deviceState: stateURL, app: "test", recognize: fake("a"))
        let before = try vault.revisionNames(of: id).count
        XCTAssertNil(try vault.recognizeNote(id, deviceState: stateURL, app: "test", recognize: { _ in
            XCTFail("a current page is not read again"); return Recognition(engine: "x", text: "")
        }))
        XCTAssertEqual(try vault.revisionNames(of: id).count, before)
        // A note without ink needs nothing either.
        let empty = try note(vault, title: "E", strokes: 0)
        XCTAssertNil(try vault.recognizeNote(empty, deviceState: stateURL, app: "test", recognize: fake("x")))
    }

    func testDeletedNotesAreSkippedAndFailuresWriteNothing() throws {
        let vault = try makeVault(pqIdentity())
        let gone = try note(vault, title: "Gone", strokes: 1)
        try vault.apply([.deleteNote], to: gone, deviceState: stateURL, app: "test")
        XCTAssertNil(try vault.recognizeNote(gone, deviceState: stateURL, app: "test", recognize: fake("x")))

        struct Boom: Error {}
        let id = try note(vault, title: "T", strokes: 1)
        let count = try vault.revisionNames(of: id).count
        XCTAssertThrowsError(try vault.recognizeNote(id, deviceState: stateURL, app: "test", recognize: { _ in throw Boom() }))
        XCTAssertEqual(try vault.revisionNames(of: id).count, count)
    }

    /// Strokes added while the page was being read (another device): the text
    /// no longer describes the page and is dropped.
    func testPageEditedMeanwhileIsNotWritten() throws {
        let vault = try makeVault(pqIdentity())
        let id = try note(vault, title: "T", strokes: 1)
        let page = try vault.reconstruct(noteId: id).pages[0].id
        let report = try vault.recognizeNote(id, deviceState: stateURL, app: "test", recognize: { _ in
            try! vault.apply([.addStroke(page: page, stroke: stroke())], to: id, deviceState: self.stateURL, app: "other")
            return Recognition(engine: "fake", text: "stale")
        })
        XCTAssertNil(report)
        XCTAssertNil(try vault.reconstruct(noteId: id).pages[0].recognition)
    }

    func testOpsGuardAgainstChangedAndMissingPages() {
        let page = Page(id: UUID(), order: PageOrder.between(nil, nil), strokes: [stroke()])
        let state = NoteState(meta: NoteMeta(title: "T", created: Date(timeIntervalSince1970: 0)), pages: [page])
        let digest = RecognitionBasis.digest(of: page)
        let r = Recognition(engine: "e", text: "t")
        let ok = RecognitionJob(page: page.id, digest: digest, recognition: r)
        XCTAssertEqual(RecognitionRun.ops(for: [ok], in: state).count, 1)
        XCTAssertTrue(RecognitionRun.ops(for: [RecognitionJob(page: page.id, digest: "0", recognition: r)], in: state).isEmpty)
        XCTAssertTrue(RecognitionRun.ops(for: [RecognitionJob(page: UUID(), digest: digest, recognition: r)], in: state).isEmpty)
        XCTAssertTrue(RecognitionRun.ops(for: [ok], in: nil).isEmpty)
        var deleted = state; deleted.deleted = true
        XCTAssertTrue(RecognitionRun.ops(for: [ok], in: deleted).isEmpty)
    }

    func testRecognizedNoteJSON() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let json = try JSONEncoder().encode(RecognizedNote(id: id, title: "T", pages: 3, pagesRecognized: 2))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(obj["note"] as? String, id.uuidString)
        XCTAssertEqual(obj["pagesRecognized"] as? Int, 2)
    }
}

final class SearchMatchesTests: XCTestCase {
    private func page(_ words: [(String, Double)], strokes: Int = 0) -> Page {
        var p = Page(id: UUID(), order: PageOrder.between(nil, nil))
        p.recognition = Recognition(engine: "t", text: words.map(\.0).joined(separator: " "),
                                    words: words.map { .init(text: $0.0, box: .init(x: $0.1, y: 0, w: 10, h: 5)) })
        return p
    }

    func testMatchesAcrossPagesInOrder() {
        let pages = [page([("Wombat", 0), ("eats", 20), ("roots", 40)]),
                     page([("nothing", 0)]),
                     page([("wombats", 5), ("Café", 30), ("WOMBAT", 60)])]
        let m = SearchMatches.matches("wombat", in: pages)
        XCTAssertEqual(m.map(\.text), ["Wombat", "wombats", "WOMBAT"])
        XCTAssertEqual(m.map(\.page), [1, 3, 3])
        XCTAssertEqual(m.map(\.pageId), [pages[0].id, pages[2].id, pages[2].id])
        XCTAssertEqual(m.map(\.box.x), [0, 5, 60])
        XCTAssertEqual(SearchMatches.matches("cafe", in: pages).map(\.text), ["Café"], "accents are ignored")
    }

    func testSeveralWordsAndTagsAndEmptyQueries() {
        let pages = [page([("red", 0), ("green", 20), ("blue", 40)])]
        XCTAssertEqual(SearchMatches.matches("RED blue", in: pages).map(\.text), ["red", "blue"])
        XCTAssertEqual(SearchMatches.matches("#red", in: pages), [], "a #word only matches tags")
        XCTAssertEqual(SearchMatches.matches("  ", in: pages), [])
        XCTAssertEqual(SearchMatches.matches("red", in: []), [])
        // Text without boxes (an import without words) cannot be located.
        var bare = page([])
        bare.recognition = Recognition(engine: "t", text: "red")
        XCTAssertEqual(SearchMatches.matches("red", in: [bare]), [])
    }

    func testMatchListIsCapped() {
        let many = page((0..<(SearchMatches.maxMatches + 50)).map { ("a", Double($0)) })
        XCTAssertEqual(SearchMatches.matches("a", in: [many]).count, SearchMatches.maxMatches)
    }
}

final class SearchMatchCursorTests: XCTestCase {
    private func page(_ words: [(String, Double)]) -> Page {
        var p = Page(id: UUID(), order: PageOrder.between(nil, nil))
        p.recognition = Recognition(engine: "t", text: words.map(\.0).joined(separator: " "),
                                    words: words.map { .init(text: $0.0, box: .init(x: $0.1, y: $0.1, w: 10, h: 5)) })
        return p
    }

    func testStartsOnThePreferredPageAndWrapsAround() throws {
        let pages = [page([("cat", 0), ("dog", 10)]), page([("cat", 0), ("cat", 30)]), page([("bird", 0)])]
        var c = try XCTUnwrap(SearchMatchCursor(query: "cat", pages: pages))
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.position, 1)
        XCTAssertEqual(c.current.page, 1)
        c.step(1); c.step(1)
        XCTAssertEqual(c.position, 3)
        XCTAssertEqual(c.current.box.y, 30)
        c.step(1)
        XCTAssertEqual(c.position, 1, "next after the last wraps to the first")
        c.step(-1)
        XCTAssertEqual(c.position, 3, "previous before the first wraps to the last")
        c.step(-7)   // far steps stay in range
        XCTAssertTrue((1...3).contains(c.position))

        let onSecond = try XCTUnwrap(SearchMatchCursor(query: "cat", pages: pages, preferredPage: pages[1].id))
        XCTAssertEqual(onSecond.position, 2)
        XCTAssertEqual(onSecond.matches(onPage: pages[1].id).map(\.index), [1, 2])
        XCTAssertEqual(onSecond.matches(onPage: pages[2].id).count, 0)
        // A preferred page without a match falls back to the first match.
        XCTAssertEqual(SearchMatchCursor(query: "cat", pages: pages, preferredPage: pages[2].id)?.position, 1)
    }

    func testNoBoxesNoCursor() {
        XCTAssertNil(SearchMatchCursor(query: "zebra", pages: [page([("cat", 0)])]))
        XCTAssertNil(SearchMatchCursor(query: "#cat", pages: [page([("cat", 0)])]))
        XCTAssertNil(SearchMatchCursor(query: "cat", pages: []))
    }

    func testRefreshKeepsTheCurrentMatchOrMovesOn() throws {
        var pages = [page([("cat", 0), ("cat", 20), ("cat", 40)])]
        var c = try XCTUnwrap(SearchMatchCursor(query: "cat", pages: pages))
        c.step(1)   // the one at y = 20
        // Unchanged pages: same match.
        XCTAssertEqual(c.refreshed(pages: pages)?.position, 2)
        // The current word disappears: the next one after it.
        pages[0].recognition?.words.remove(at: 1)
        let moved = try XCTUnwrap(c.refreshed(pages: pages))
        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(moved.current.box.y, 40)
        // Nothing matches any more.
        pages[0].recognition = nil
        XCTAssertNil(c.refreshed(pages: pages))
    }
}
