import Foundation
import XCTest
@testable import Sempere

final class NotebookTests: XCTestCase {
    func testComponentsTrimAndDropEmptySegments() {
        XCTAssertEqual(NotebookPath.components(" A//B / "), ["A", "B"])
        XCTAssertEqual(NotebookPath.components("/Research/Daily log/"), ["Research", "Daily log"])
        XCTAssertEqual(NotebookPath.components("School"), ["School"])
        XCTAssertEqual(NotebookPath.components(nil), [])
        XCTAssertEqual(NotebookPath.components(" / // "), [])
        XCTAssertEqual(NotebookPath.canonical(" A//B / "), "A/B")
        XCTAssertNil(NotebookPath.canonical("//"))
        XCTAssertNil(NotebookPath.canonical(nil))
    }

    func testWithinComparesWholeSegments() {
        XCTAssertTrue(NotebookPath.name("A/B/C", isWithin: "A"))
        XCTAssertTrue(NotebookPath.name("A/B/C", isWithin: "A/B"))
        XCTAssertTrue(NotebookPath.name("A/B", isWithin: "A/B"))
        XCTAssertTrue(NotebookPath.name(" A / B ", isWithin: "A/B"))
        XCTAssertFalse(NotebookPath.name("A/Bc", isWithin: "A/B"))
        XCTAssertFalse(NotebookPath.name("A", isWithin: "A/B"))
        XCTAssertFalse(NotebookPath.name("B/A", isWithin: "A"))
        XCTAssertFalse(NotebookPath.name(nil, isWithin: "A"))
        XCTAssertFalse(NotebookPath.name("A", isWithin: ""))
    }

    func testRenameReplacesThePrefix() {
        XCTAssertEqual(NotebookPath.renamed("A/B/C", from: "A", to: "X"), "X/B/C")
        XCTAssertEqual(NotebookPath.renamed("A/B/C", from: "A/B", to: "Y/Z"), "Y/Z/C")
        XCTAssertEqual(NotebookPath.renamed("A", from: "A", to: "X/A"), "X/A")
        XCTAssertEqual(NotebookPath.renamed(" A //B", from: "A", to: " X "), "X/B")
        // An empty target takes the notebook away and lifts its children.
        XCTAssertNil(NotebookPath.renamed("A", from: "A", to: ""))
        XCTAssertNil(NotebookPath.renamed("A", from: "A", to: nil))
        XCTAssertEqual(NotebookPath.renamed("A/B", from: "A", to: " "), "B")
        // Outside the renamed notebook: untouched, raw spelling kept.
        XCTAssertEqual(NotebookPath.renamed("Ab/B", from: "A", to: "X"), "Ab/B")
        XCTAssertEqual(NotebookPath.renamed(" Q ", from: "A", to: "X"), " Q ")
        XCTAssertNil(NotebookPath.renamed(nil, from: "A", to: "X"))
    }

    func testTreeBuildsIntermediateLevelsAndSorts() {
        let tree = NotebookNode.tree(["School/Math 10", "School/Math 9", "Research/Daily log/2026",
                                      "School", nil, "  ", "/School/ Math 9 /", "Archive"])
        XCTAssertEqual(tree.map(\.name), ["Archive", "Research", "School"])
        XCTAssertEqual(tree.map(\.path), ["Archive", "Research", "School"])
        let research = tree[1]
        XCTAssertEqual(research.children.map(\.path), ["Research/Daily log"])
        XCTAssertEqual(research.children[0].children.map(\.path), ["Research/Daily log/2026"])
        XCTAssertEqual(research.children[0].children[0].name, "2026")
        XCTAssertNil(research.children[0].children[0].childrenOrNil)
        XCTAssertEqual(tree[2].children.map(\.name), ["Math 9", "Math 10"])   // numeric-aware order
        XCTAssertNil(tree[0].childrenOrNil)
        XCTAssertEqual(NotebookNode.flatten(tree),
                       ["Archive", "Research", "Research/Daily log", "Research/Daily log/2026",
                        "School", "School/Math 9", "School/Math 10"])
        XCTAssertEqual(NotebookNode.tree([]), [])
    }

    func testSameNameUnderDifferentParentsStaysSeparate() {
        let tree = NotebookNode.tree(["A/Notes", "B/Notes"])
        XCTAssertEqual(NotebookNode.flatten(tree), ["A", "A/Notes", "B", "B/Notes"])
        XCTAssertEqual(Set(NotebookNode.flatten(tree)).count, 4)
    }
}

final class NotebookSuggestionTests: XCTestCase {
    private let notebooks: [String?] = ["School/Math 9", "School/Math 10", "School/Physics", "Work/Atlas", "Personal", nil,
                                        "  School // Math 9 ", "Café/Menu"]

    func testBlankTextOffersEveryNotebookAndLevel() {
        XCTAssertEqual(NotebookPath.suggestions(matching: "", among: notebooks),
                       ["Café", "Café/Menu", "Personal", "School", "School/Math 9", "School/Math 10", "School/Physics",
                        "Work", "Work/Atlas"])
        XCTAssertEqual(NotebookPath.suggestions(matching: " / ", among: notebooks).count, 9)
        XCTAssertEqual(NotebookPath.suggestions(matching: "", among: []), [])
    }

    func testFiltersAsYouTypeIgnoringCaseAndAccents() {
        XCTAssertEqual(NotebookPath.suggestions(matching: "sch", among: notebooks),
                       ["School", "School/Math 9", "School/Math 10", "School/Physics"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "CAFE", among: notebooks), ["Café", "Café/Menu"])
        // A level starting with the text ranks above a mere substring.
        XCTAssertEqual(NotebookPath.suggestions(matching: "math", among: notebooks), ["School/Math 9", "School/Math 10"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "at", among: notebooks),
                       ["Work/Atlas", "School/Math 9", "School/Math 10"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "zzz", among: notebooks), [])
    }

    func testTypedPathIsCanonicalisedBeforeMatching() {
        XCTAssertEqual(NotebookPath.suggestions(matching: " school // math ", among: notebooks),
                       ["School/Math 9", "School/Math 10"])
        // The notebook typed exactly comes first, then what lies below it.
        XCTAssertEqual(NotebookPath.suggestions(matching: "School", among: notebooks).first, "School")
    }

    func testTrailingSlashOffersTheChildren() {
        XCTAssertEqual(NotebookPath.suggestions(matching: "School/", among: notebooks),
                       ["School/Math 9", "School/Math 10", "School/Physics"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "school/ph", among: notebooks), ["School/Physics"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "Personal/", among: notebooks), [])
        XCTAssertEqual(NotebookPath.suggestions(matching: "Sch/", among: notebooks), [])   // whole levels only
    }

    func testExcludingAndLimit() {
        XCTAssertFalse(NotebookPath.suggestions(matching: "", among: notebooks, excluding: " school ").contains("School"))
        XCTAssertEqual(NotebookPath.suggestions(matching: "", among: notebooks, limit: 2), ["Café", "Café/Menu"])
        XCTAssertEqual(NotebookPath.suggestions(matching: "", among: notebooks, limit: 0), [])
        XCTAssertEqual(NotebookPath.suggestions(matching: "x", among: notebooks, limit: -1), [])
    }

    /// Every suggestion is a canonical name, so picking it needs no further cleanup.
    func testSuggestionsAreCanonical() {
        for text in ["", "s", "school/", "/"] {
            for s in NotebookPath.suggestions(matching: text, among: notebooks) {
                XCTAssertEqual(NotebookPath.canonical(s), s)
            }
        }
    }
}
