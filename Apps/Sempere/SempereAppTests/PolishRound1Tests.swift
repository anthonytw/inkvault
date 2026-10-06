import Foundation
import PencilKit
import Sempere
import Testing
@testable import SempereApp

/// App polish round 1: the notebook combo box, the "Recognize All Notes"
/// results list, and highlighting a search hit on the canvas.
@MainActor
struct PolishRound1Tests {
    static let lecture = AppModelTests.lecture

    // MARK: notebook combo box

    @Test func comboBoxOffersExistingNotebooksAsYouType() {
        let notebooks = ["School", "School/Math", "School/Physics", "Work", "Work/Atlas"]
        #expect(NotebookChoices.rows(matching: "", among: notebooks) == notebooks)
        #expect(NotebookChoices.rows(matching: "sch", among: notebooks) == ["School", "School/Math", "School/Physics"])
        #expect(NotebookChoices.rows(matching: "school/", among: notebooks) == ["School/Math", "School/Physics"])
        #expect(NotebookChoices.rows(matching: "atl", among: notebooks) == ["Work/Atlas"])
        #expect(NotebookChoices.rows(matching: "", among: notebooks, excluding: "School").first == "School/Math")
        #expect(NotebookChoices.rows(matching: "", among: notebooks, limit: 2) == ["School", "School/Math"])
        #expect(NotebookChoices.rows(matching: "zzz", among: notebooks).isEmpty)
    }

    @Test func aTypedPathIsNewUnlessSomeNoteHasIt() {
        let notebooks = ["School", "School/Math"]
        #expect(NotebookChoices.isNew("School/Chemistry", among: notebooks))
        #expect(NotebookChoices.isNew(" school//Math ", among: notebooks), "case differs: a different notebook")
        #expect(!NotebookChoices.isNew(" School // Math ", among: notebooks))
        #expect(!NotebookChoices.isNew("", among: notebooks))
        #expect(!NotebookChoices.isNew(" / ", among: notebooks))
        #expect(NotebookChoices.display("School/Math") == "School › Math")
    }

    @Test func aTypedNewPathIsCanonicalisedWhenANoteMovesThere() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = try await model.createNote(title: "Loose", paper: .ruled, notebook: nil)
        try await model.moveNote(id, toNotebook: "  School // Math 9 ")
        #expect(model.notes.first { $0.id == id }?.notebook == "School/Math 9")
        // The combo box now offers it, parents included.
        #expect(NotebookChoices.rows(matching: "math", among: model.notebooks) == ["School/Math 9"])
        #expect(NotebookChoices.rows(matching: "sch", among: model.notebooks) == ["School", "School/Math 9"])
    }

    // MARK: recognition results

    @Test func recognizeAllKeepsAListOfTheNotesItChanged() async throws {
        let fake = FakeRecognizer()
        let (model, vault, pages) = try await SearchTests.model(recognizer: fake, texts: nil)
        #expect(model.recognitionResults == nil)
        model.startRecognizingNotes()
        #expect(model.recognitionResults?.finished == false)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })

        let results = try #require(model.recognitionResults)
        #expect(results.finished && !results.stopped && results.failed == 0)
        #expect(results.headline == "Recognized 1 note")
        let entry = try #require(results.notes.first)
        #expect(entry.id == Self.lecture)
        #expect(entry.title == "Fixture lecture")
        #expect(entry.pages == pages.count && entry.pagesRecognized == pages.count)

        // "Recently Recognized" lists exactly those notes, and survives later activity.
        model.sidebarSelection = .recentlyRecognized
        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        model.sidebarSelection = .allNotes
        model.startRecognizingNotes()   // nothing needs reading: the list stays until a run really starts
        #expect(model.recognitionResults == results)

        // The next run replaces it, and a dismissed bar comes back for it.
        model.recognitionResults?.dismissed = true
        try vault.apply([.addStroke(page: pages[0], stroke: TS.stroke(x: 70, y: 90))], to: Self.lecture,
                        deviceState: TS.deviceStateURL(), app: "test")
        try await model.reload()
        #expect(model.notesNeedingRecognition.map(\.id) == [Self.lecture])
        model.startRecognizingNotes()
        #expect(model.recognitionResults?.dismissed == false)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        #expect(model.recognitionResults?.notes.map(\.pagesRecognized) == [1], "only the edited page was read again")
        #expect(RecognitionResultsText.pagesRead(1, of: 2) == "Read 1 of 2 pages")
    }

    @Test func aStoppedRunKeepsWhatItDidAndSaysSo() async throws {
        let gate = Gate()
        await gate.close()
        let (model, _, _) = try await SearchTests.model(recognizer: FakeRecognizer(gate: gate), texts: nil)
        model.startRecognizingNotes()
        await gate.waitForArrivals(1)
        model.cancelRecognizingNotes()
        await gate.open()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        let results = try #require(model.recognitionResults)
        #expect(results.finished && results.stopped)
        #expect(results.notes.isEmpty)
        #expect(RecognitionResultsText.detail(results, running: false) == "Stopped early")
    }

    @Test func resultsAreForgottenWhenTheVaultCloses() async throws {
        let (model, _, _) = try await SearchTests.model(recognizer: FakeRecognizer(), texts: nil)
        model.startRecognizingNotes()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { model.recognitionTask == nil })
        model.sidebarSelection = .recentlyRecognized
        model.close()
        #expect(model.recognitionResults == nil)
        #expect(model.sidebarSelection == .allNotes)
        // Not restored with a window's saved selection either.
        #expect(RestorableSelection.name(of: .recentlyRecognized) == "all")
    }

    @Test func resultTextsReadWell() {
        #expect(RecognitionResultsText.pagesRead(3, of: 3) == "Read 3 pages")
        #expect(RecognitionResultsText.pagesRead(1, of: 1) == "Read 1 page")
        var r = RecognitionResults()
        #expect(RecognitionResultsText.detail(r, running: false) == nil)
        r.failed = 2
        #expect(RecognitionResultsText.detail(r, running: true) == "Still reading… · 2 could not be read")
        #expect(RecognitionResults(notes: [RecognizedNote(id: UUID(), title: "", pages: 1, pagesRecognized: 1)]).headline
                == "Recognized 1 note")
    }

    // MARK: search highlights

    /// The lecture with word boxes: "momentum" twice on page 2, once on page 1.
    static func modelWithWords() async throws -> (AppModel, [UUID]) {
        let (model, vault, pages) = try await SearchTests.model(texts: nil)
        func rec(_ text: String) -> Recognition {
            Recognition(engine: "notability-1", text: text,
                        words: RecognitionLayout.distribute(text: text, in: .init(x: 40, y: 100, w: 400, h: 24)))
        }
        try vault.apply([.setPageRecognition(pageId: pages[0], recognition: rec("momentum of a matrix")),
                         .setPageRecognition(pageId: pages[1], recognition: rec("momentum and more momentum"))],
                        to: Self.lecture, deviceState: TS.deviceStateURL(), app: "test")
        try await model.reload()
        return (model, pages)
    }

    @Test func openingASearchHitHighlightsItsWordsAndStepsThroughThem() async throws {
        let (model, pages) = try await Self.modelWithWords()
        model.searchText = "momentum"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        let hit = try #require(model.searchResults.first)
        model.openSearchHit(hit)
        await model.showSelectedNote()
        let editor = try #require(model.editor)

        let cursor = try #require(editor.searchCursor)
        #expect(cursor.count == 3)
        #expect(editor.currentPage?.id == hit.page?.pageId)
        #expect(cursor.current.pageId == hit.page?.pageId, "starts on the page the result named")
        #expect(editor.highlightBoxes(onPage: pages[1]).count == 2)
        #expect(editor.highlightBoxes(onPage: pages[0]).count == 1)
        #expect(editor.highlightBoxes(onPage: pages[1]).filter(\.isCurrent).count + editor.highlightBoxes(onPage: pages[0]).filter(\.isCurrent).count == 1)

        // Next and previous wrap across the pages and show the page of the match.
        let startPage = editor.currentPage?.id
        var seen: [Int] = []
        for _ in 0..<3 {
            editor.stepSearchMatch(1)
            seen.append(try #require(editor.searchCursor).position)
        }
        #expect(Set(seen) == [1, 2, 3], "every match is visited once in a lap")
        #expect(editor.currentPage?.id == startPage, "a full lap ends where it began")
        let token = editor.revealToken
        editor.stepSearchMatch(-1)
        #expect(editor.revealToken == token + 1, "the canvas is asked to scroll to the match")
        #expect(editor.currentPage?.id == editor.searchCursor?.current.pageId)

        editor.clearSearchHighlight()
        #expect(editor.searchCursor == nil)
        #expect(editor.highlightBoxes(onPage: pages[1]).isEmpty)
    }

    @Test func noHighlightWhenOnlyTheTitleMatchedOrAPageWasEdited() async throws {
        let (model, pages) = try await Self.modelWithWords()
        model.searchText = "fixture lecture"
        #expect(await TS.waitUntil { !model.searchResults.isEmpty })
        model.openSearchHit(try #require(model.searchResults.first))
        await model.showSelectedNote()
        #expect(model.editor?.searchCursor == nil, "a title match has no word boxes")

        // A page whose strokes changed here has stale boxes: left out of the highlight.
        let editor = try #require(model.editor)
        editor.highlightSearch(query: "momentum", page: pages[0])
        #expect(editor.searchCursor?.count == 3)
        var drawing = editor.drawing(for: pages[1])
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 400)))
        editor.drawingDidChange(pageID: pages[1], drawing: drawing, tool: nil)
        editor.stepSearchMatch(1)
        #expect(editor.searchCursor?.matches.allSatisfy { $0.pageId == pages[0] } == true)
    }

    @Test func theMatchBarCountsMatches() {
        #expect(SearchMatchBar.label(position: 3, count: 12) == "3 of 12 matches")
        #expect(SearchMatchBar.label(position: 1, count: 1) == "1 match")
    }
}
