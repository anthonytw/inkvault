import Foundation
import XCTest
@testable import Sempere

final class NoteSearchTests: XCTestCase {
    private func note(_ title: String, notebook: String? = nil, tags: [String] = [], pages: [String] = [],
                      modified: TimeInterval = 0) -> NoteSummary {
        var s = NoteSummary(id: UUID(), title: title, tags: tags, notebook: notebook, deleted: false, pages: pages.count,
                            strokes: 0, modified: Date(timeIntervalSince1970: modified), problem: nil)
        s.pageTexts = pages.enumerated().compactMap { i, t in
            t.isEmpty ? nil : PageText(pageId: UUID(), number: i + 1, text: t)
        }
        return s
    }

    func testFindsHandwritingAndNamesThePage() throws {
        let a = note("Physics", pages: ["Newton's laws", "", "Kinetic energy and momentum"])
        let b = note("Chemistry", pages: ["Periodic table"])
        let hits = NoteSearch.search("momentum", in: [a, b])
        XCTAssertEqual(hits.map(\.note), [a.id])
        XCTAssertEqual(hits[0].page?.number, 3)
        XCTAssertEqual(hits[0].page?.pageId, a.pageTexts[1].pageId)
        XCTAssertEqual(hits[0].fields, [.text])
        let snippet = try XCTUnwrap(hits[0].snippet)
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["momentum"])
    }

    func testIgnoresCaseAccentsAndWidth() {
        let a = note("Reunión", pages: ["Café con leche", "ＦＵＬＬ width"])
        XCTAssertEqual(NoteSearch.search("reunion", in: [a]).count, 1)
        XCTAssertEqual(NoteSearch.search("CAFE", in: [a]).first?.page?.number, 1)
        XCTAssertEqual(NoteSearch.search("full", in: [a]).first?.page?.number, 2)
    }

    func testEveryWordMustMatchAndNotesMatchAcrossFields() {
        let a = note("Linear algebra", notebook: "School/Math", tags: ["exam"], pages: ["eigenvalues of a matrix"])
        let b = note("Cooking", pages: ["matrix of flavours"])
        XCTAssertEqual(NoteSearch.search("matrix eigenvalues", in: [a, b]).map(\.note), [a.id])
        // Title + tag + notebook + text together.
        let hit = NoteSearch.search("linear exam math matrix", in: [a, b])
        XCTAssertEqual(hit.map(\.note), [a.id])
        XCTAssertEqual(hit[0].fields, [.title, .tag, .notebook, .text])
        XCTAssertTrue(NoteSearch.search("matrix unicorn", in: [a, b]).isEmpty)
        XCTAssertTrue(NoteSearch.search("   ", in: [a]).isEmpty)
        XCTAssertTrue(NoteSearch.search("", in: [a]).isEmpty)
    }

    func testHashWordsMatchTagsOnly() {
        let tagged = note("A", tags: ["Physics"])
        let titled = note("Physics notes", pages: ["physics"])
        XCTAssertEqual(NoteSearch.search("#physics", in: [tagged, titled]).map(\.note), [tagged.id])
        XCTAssertEqual(NoteSearch.search("#phys", in: [tagged, titled]).map(\.note), [tagged.id], "substring of a tag")
        XCTAssertEqual(Set(NoteSearch.search("physics", in: [tagged, titled]).map(\.note)), [tagged.id, titled.id])
        XCTAssertTrue(NoteSearch.search("#", in: [tagged]).isEmpty)
    }

    func testRanksTitleOverTagOverNotebookOverText() {
        let text = note("Misc", pages: ["history of art"], modified: 100)
        let nb = note("Misc 2", notebook: "History", modified: 100)
        let tag = note("Misc 3", tags: ["history"], modified: 100)
        let title = note("History", modified: 0)
        let ranked = NoteSearch.search("history", in: [text, nb, tag, title]).map(\.note)
        XCTAssertEqual(ranked, [title.id, tag.id, nb.id, text.id])
    }

    func testTiesGoToTheNewestNote() {
        let old = note("Same", modified: 10), new = note("Same", modified: 20)
        XCTAssertEqual(NoteSearch.search("same", in: [old, new]).map(\.note), [new.id, old.id])
    }

    func testBestPageHasMostWordsThenTheEarliest() {
        let n = note("N", pages: ["alpha", "alpha beta", "beta alpha", "gamma"])
        let hit = NoteSearch.search("alpha beta", in: [n])[0]
        XCTAssertEqual(hit.page?.number, 2)
        XCTAssertEqual(hit.matchedPages, 3)
        XCTAssertEqual(NoteSearch.search("alpha", in: [n])[0].page?.number, 1)
    }

    func testTitleOnlyHitHasNoPage() {
        let n = note("Budget", pages: ["unrelated"])
        let hit = NoteSearch.search("budget", in: [n])[0]
        XCTAssertNil(hit.page)
        XCTAssertNil(hit.snippet)
        XCTAssertEqual(hit.fields, [.title])
    }

    func testSnippetIsFlattenedTrimmedAndMarked() throws {
        let long = String(repeating: "word ", count: 60) + "needle\nsecond line " + String(repeating: "tail ", count: 60)
        let hit = NoteSearch.search("needle", in: [note("N", pages: [long])])[0]
        let s = try XCTUnwrap(hit.snippet)
        XCTAssertTrue(s.text.hasPrefix("…") && s.text.hasSuffix("…"))
        XCTAssertFalse(s.text.contains("\n"))
        XCTAssertLessThan(s.text.count, 160)
        XCTAssertEqual(s.matches.map { String(s.text[$0]) }, ["needle"])
        XCTAssertTrue(s.text.contains("second line"))
    }

    func testQueryWordsAreCappedAndDeduplicated() {
        let n = note("N", pages: ["a b c"])
        XCTAssertEqual(NoteSearch.words("a A a").count, 2, "case differs, so two words")
        XCTAssertEqual(NoteSearch.words((0..<100).map(String.init).joined(separator: " ")).count, NoteSearch.maxWords)
        XCTAssertEqual(NoteSearch.search("a a a a", in: [n]).count, 1)
    }
}
