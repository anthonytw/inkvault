import Foundation
import Sempere
import Testing
import UniformTypeIdentifiers
@testable import SempereApp

/// Dragging notes and notebooks onto the sidebar, and "Move Notebook To…":
/// the payloads, the rules (what a row accepts) and the moves they make.
/// The drop delegates themselves need a real drag session and are not run here.
@MainActor
struct DragAndDropTests {
    // MARK: payloads

    @Test func payloadsRoundTripAndMalformedOnesAreRejected() throws {
        let ids = [UUID(), UUID()]
        let notes = DragPayload.notes(ids)
        #expect(DragPayload.decode(notes.data, as: .sempereNotes) == notes)
        #expect(notes.type == .sempereNotes)
        let book = DragPayload.notebook("School/Math")
        #expect(DragPayload.decode(book.data, as: .sempereNotebook) == book)
        #expect(DragPayload.decode(Data(" A // B ".utf8), as: .sempereNotebook) == .notebook("A/B"))

        #expect(DragPayload.decode(Data(), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data("not json".utf8), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data(#"["nope"]"#.utf8), as: .sempereNotes) == nil)
        #expect(DragPayload.decode(Data(" / ".utf8), as: .sempereNotebook) == nil)
        #expect(DragPayload.decode(Data(repeating: 0x41, count: DragPayload.maxPathBytes + 1), as: .sempereNotebook) == nil)
        #expect(DragPayload.decode(notes.data, as: .pdf) == nil)
        #expect(DragPayload.decode(Data(repeating: 0x20, count: DragPayload.maxNotes * 48 + 1), as: .sempereNotes) == nil)
        // Ids that do parse are kept, the others dropped.
        let mixed = Data(#"["\#(ids[0].uuidString)", "x"]"#.utf8)
        #expect(DragPayload.decode(mixed, as: .sempereNotes) == .notes([ids[0]]))
    }

    @Test func onlyNotebooksAndAllNotesTakeDrops() {
        #expect(DropTarget(.allNotes) == .topLevel)
        #expect(DropTarget(.notebook(" A // B ")) == .notebook("A/B"))
        #expect(DropTarget(.tag("x")) == nil)
        #expect(DropTarget(.deleted) == nil)
        #expect(DropTarget(.recentlyRecognized) == nil)
        #expect(DropTarget.topLevel.path == nil)
        #expect(DropTarget.notebook("A").path == "A")
        #expect(DropTarget.notebook(" A // B ").path == "A/B", "always canonical")
    }

    // MARK: rules

    static func summary(_ notebook: String?, deleted: Bool = false) -> NoteSummary {
        NoteSummary(id: UUID(), title: "t", tags: [], notebook: notebook, deleted: deleted, pages: 1, strokes: 0,
                    modified: nil, problem: nil)
    }

    @Test func notesAreAcceptedWhereTheyWouldMove() {
        let inMath = Self.summary("School/Math"), loose = Self.summary(nil), gone = Self.summary("X", deleted: true)
        let all = [inMath, loose, gone]
        #expect(SidebarDrop.accepts(.notes([inMath.id]), on: .notebook("Archive"), notes: all))
        #expect(!SidebarDrop.accepts(.notes([inMath.id]), on: .notebook(" School/ Math "), notes: all), "already there")
        #expect(SidebarDrop.accepts(.notes([inMath.id]), on: .topLevel, notes: all), "out of its notebook")
        #expect(!SidebarDrop.accepts(.notes([loose.id]), on: .topLevel, notes: all), "already at the top level")
        #expect(SidebarDrop.accepts(.notes([inMath.id, loose.id]), on: .notebook("School/Math"), notes: all), "one of them moves")
        #expect(!SidebarDrop.accepts(.notes([gone.id]), on: .notebook("Archive"), notes: all), "deleted notes stay put")
        #expect(!SidebarDrop.accepts(.notes([UUID()]), on: .notebook("Archive"), notes: all), "unlisted id")
        #expect(!SidebarDrop.accepts(.notes([]), on: .topLevel, notes: all))
    }

    @Test func aNotebookNeverDropsIntoItselfItsDescendantsOrWhereItIs() {
        let none: [NoteSummary] = []
        #expect(SidebarDrop.accepts(.notebook("School/Math"), on: .notebook("Archive"), notes: none))
        #expect(SidebarDrop.accepts(.notebook("School/Math"), on: .topLevel, notes: none))
        #expect(!SidebarDrop.accepts(.notebook("Math"), on: .topLevel, notes: none), "top-level already")
        #expect(!SidebarDrop.accepts(.notebook("School/Math"), on: .notebook("School"), notes: none), "its own parent")
        #expect(!SidebarDrop.accepts(.notebook("School"), on: .notebook("School"), notes: none), "into itself")
        #expect(!SidebarDrop.accepts(.notebook("School"), on: .notebook("School/Math/Algebra"), notes: none), "into a descendant")
        #expect(SidebarDrop.accepts(.notebook("A/B"), on: .notebook("A/Bc"), notes: none), "A/Bc is not inside A/B")
        #expect(SidebarDrop.actionName(.notes([UUID()])) == "Move Note")
        #expect(SidebarDrop.actionName(.notes([UUID(), UUID()])) == "Move Notes")
        #expect(SidebarDrop.actionName(.notebook("A")) == "Move Notebook")
    }

    // MARK: moving notes

    @Test func droppedNotesMoveInOneCommitAndUndoPutsThemBack() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        let vault = try #require(model.vault)
        let plan = try #require(ids["Plan"]), lab = try #require(ids["Lab"]), loose = try #require(ids["Loose"])
        let labBefore = try vault.revisionNames(of: lab).count
        let looseBefore = try vault.revisionNames(of: loose).count

        let record = try #require(try await model.moveNotes([plan, lab, lab, UUID()], toNotebook: " Archive // 2026 "))
        func notebook(_ id: UUID) -> String? { model.notes.first { $0.id == id }?.notebook }
        #expect(notebook(plan) == "Archive/2026" && notebook(lab) == "Archive/2026")
        #expect(record.previous == [plan: "Research", lab: "Research/Lab"])
        #expect(try vault.revisionNames(of: lab).count == labBefore + 1, "a note listed twice is written once")
        #expect(try vault.revisionNames(of: loose).count == looseBefore, "others are not touched")

        // Already there: nothing to do, nothing written.
        #expect(try await model.moveNotes([plan], toNotebook: "Archive/2026") == nil)
        #expect(try vault.revisionNames(of: plan).count == 2)

        try await model.restoreNotebooks(record)
        #expect(notebook(plan) == "Research" && notebook(lab) == "Research/Lab")

        // To the top level; deleted notes are left where they are.
        try await model.deleteNote(lab)
        let out = try #require(try await model.moveNotes([plan, lab], toNotebook: nil))
        #expect(notebook(plan) == nil && notebook(lab) == "Research/Lab")
        #expect(Set(out.previous.keys) == [plan])
    }

    // MARK: moving notebooks

    @Test func droppingANotebookNestsItsWholeSubtree() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        let vault = try #require(model.vault)
        let other = try #require(ids["Other"])
        let otherBefore = try vault.revisionNames(of: other).count
        func notebook(_ title: String) -> String? { model.notes.first { $0.title == title }?.notebook }

        let record = try #require(try await model.moveNotebook("Research", into: "School/Math 9"))
        #expect(notebook("Plan") == "School/Math 9/Research")
        #expect(notebook("Daily") == "School/Math 9/Research/Daily log")
        #expect(notebook("Old day") == "School/Math 9/Research/Daily log/2025")
        #expect(notebook("Lab") == "School/Math 9/Research/Lab")
        #expect(notebook("Other") == "Researcher", "same prefix, other notebook")
        #expect(try vault.revisionNames(of: other).count == otherBefore)
        #expect(record.previous.count == 4)

        // Undo puts every note back, and un-nesting is a move to the top level.
        try await model.restoreNotebooks(record)
        #expect(notebook("Lab") == "Research/Lab" && notebook("Plan") == "Research")
        try await model.moveNotebook("Research/Daily log", into: nil)
        #expect(notebook("Daily") == "Daily log")
        #expect(notebook("Old day") == "Daily log/2025")
    }

    @Test func aNotebookCannotBeDroppedIntoItselfOrItsDescendants() async throws {
        let (model, _) = try await NotebookTreeTests.model()
        let before = model.notes.map { "\($0.id)|\($0.notebook ?? "-")" }.sorted()
        for parent in ["Research", "Research/Lab", "Research/Daily log/2025"] {
            await #expect(throws: AppModel.ModelError.invalidNotebookMove) {
                try await model.moveNotebook("Research", into: parent)
            }
        }
        #expect(model.notes.map { "\($0.id)|\($0.notebook ?? "-")" }.sorted() == before)
        // Where it is already: nothing to do.
        #expect(try await model.moveNotebook("Research/Lab", into: "Research") == nil)
        #expect(try await model.moveNotebook("Research", into: nil) == nil)
    }

    @Test func droppingOntoAnExistingNotebookMergesThem() async throws {
        let (model, _) = try await NotebookTreeTests.model()
        // "Research/Lab" into "School": School/Lab; and a second notebook with that name merges.
        _ = try await model.createNote(title: "Lab2", paper: .ruled, notebook: "School/Lab")
        try await model.moveNotebook("Research/Lab", into: "School")
        #expect(model.notes.filter { $0.notebook == "School/Lab" }.map(\.title).sorted() == ["Lab", "Lab2"])
    }

    @Test func renameNotebookReportsWhatItChanged() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        let previous = try await model.renameNotebook("Research/Daily log", to: "Journal")
        #expect(previous == [try #require(ids["Daily"]): "Research/Daily log", try #require(ids["Old day"]): "Research/Daily log/2025"])
        #expect(try await model.renameNotebook("Journal", to: "Journal").isEmpty)
    }

    // MARK: the drop and its undo

    @Test func aDropRegistersOneUndoStep() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        let lab = try #require(ids["Lab"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        func notebook() -> String? { model.notes.first { $0.id == lab }?.notebook }

        undo.beginUndoGrouping()
        await model.move(.notes([lab]), to: .notebook("School"), undoManager: undo)
        undo.endUndoGrouping()
        #expect(notebook() == "School")
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Move Note")
        undo.undo()
        #expect(await TS.waitUntil { notebook() == "Research/Lab" })

        // A rejected drop (into itself) changes nothing and registers nothing.
        let steps = undo.canUndo
        await model.move(.notebook("Research"), to: .notebook("Research/Lab"), undoManager: undo)
        #expect(model.errorMessage == nil)
        #expect(undo.canUndo == steps)
        #expect(model.notes.first { $0.id == lab }?.notebook == "Research/Lab")

        // A notebook drop, then undo.
        undo.beginUndoGrouping()
        await model.move(.notebook("Research/Lab"), to: .topLevel, undoManager: undo)
        undo.endUndoGrouping()
        #expect(notebook() == "Lab")
        undo.undo()
        #expect(await TS.waitUntil { notebook() == "Research/Lab" })
    }

    /// The model is shared by every window on a Mac: a drop's undo goes to the
    /// window it happened in, never to another window's undo manager.
    @Test func aDropsUndoGoesToItsOwnWindow() async throws {
        let (model, ids) = try await NotebookTreeTests.model()
        let lab = try #require(ids["Lab"])
        let here = UndoManager(), other = UndoManager()
        here.groupsByEvent = false
        other.groupsByEvent = false
        here.beginUndoGrouping()
        await model.move(.notes([lab]), to: .notebook("School"), undoManager: here)
        here.endUndoGrouping()
        #expect(here.canUndo)
        #expect(!other.canUndo)
    }

    @Test func theMoveNotebookSheetOnlyOffersLegalMoves() {
        #expect(MoveNotebookView.result(of: "School/Math", into: "Archive") == "Archive/Math")
        #expect(MoveNotebookView.result(of: "School/Math", into: "") == "Math")
        #expect(MoveNotebookView.result(of: "School/Math", into: "School") == nil, "it is there already")
        #expect(MoveNotebookView.result(of: "School", into: "School/Math") == nil)
        // The combo box leaves out the notebook and its descendants.
        let all = ["A", "A/B", "A/B/C", "D"]
        #expect(NotebookChoices.rows(matching: "", among: all, excludingSubtree: "A/B") == ["A", "D"])
    }
}
