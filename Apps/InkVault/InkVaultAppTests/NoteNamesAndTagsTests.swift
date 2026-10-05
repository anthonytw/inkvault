import Foundation
import InkVault
import Testing
@testable import InkVaultApp

/// Renaming, tags (case-insensitive) and same-titled notes in the model.
@MainActor
struct NoteNamesAndTagsTests {
    @Test func renamingChangesOnlyTheTitleThroughADelta() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let id = AppModelTests.lecture
        let before = try #require(model.notes.first { $0.id == id })
        try await model.renameNote(id, to: "  Renamed lecture ")
        let after = try #require(model.notes.first { $0.id == id })
        #expect(after.title == "Renamed lecture")
        #expect(after.tags == before.tags)
        #expect(after.notebook == before.notebook)
        try await model.reload()
        #expect(model.notes.first { $0.id == id }?.title == "Renamed lecture")
        try await model.renameNote(id, to: "Renamed lecture")   // unchanged: no delta needed
    }

    @Test func sameTitlesWorkInOneNotebookAndAcrossNotebooks() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let a = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "School")
        let b = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "School")
        let c = try await model.createNote(title: "Notes", paper: Paper(kind: .ruled), notebook: "Work")
        #expect(Set([a, b, c]).count == 3)
        #expect(model.notes.filter { $0.title == "Notes" }.count == 3)
        model.sidebarSelection = .notebook("School")
        #expect(Set(model.visibleNotes.filter { $0.title == "Notes" }.map(\.id)) == [a, b])

        // Selection and the open note follow the id.
        model.selectedNoteID = b
        try await model.openEditor(for: b)
        #expect(model.editor?.noteID == b)
        #expect(model.selectedNote?.id == b)
        try await model.renameNote(a, to: "Notes")          // a taken title: allowed
        try await model.renameNote(c, to: "Renamed")
        #expect(model.selectedNoteID == b)
        #expect(model.editor?.noteID == b)
        model.selectedNoteID = a
        try await model.openEditor(for: a)
        #expect(model.editor?.noteID == a)
        #expect(model.selectedNote?.id == a)

        // Each edits independently.
        try await model.addTag("only-a", to: a)
        #expect(model.notes.first { $0.id == a }?.tags == ["only-a"])
        #expect(model.notes.first { $0.id == b }?.tags == [])
        try await model.deleteNote(b)
        #expect(model.notes.first { $0.id == a }?.deleted == false)
        #expect(model.notes.first { $0.id == b }?.deleted == true)
        try await model.reload()
        #expect(model.notes.filter { $0.title == "Notes" }.count == 2)
    }

    @Test func tagsMatchIgnoringCaseAndShowTheFirstSpelling() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let a = try await model.createNote(title: "A", paper: Paper(kind: .ruled), notebook: nil)
        let b = try await model.createNote(title: "B", paper: Paper(kind: .ruled), notebook: nil)
        try await model.addTag("  Fall   Term ", to: a)
        #expect(model.notes.first { $0.id == a }?.tags == ["Fall Term"])   // multi-word, whitespace collapsed
        try await model.addTag("fall term", to: b)                         // the vault's spelling wins
        #expect(model.notes.first { $0.id == b }?.tags == ["Fall Term"])
        try await model.addTag("FALL TERM", to: a)                         // already has it
        #expect(model.notes.first { $0.id == a }?.tags == ["Fall Term"])
        #expect(model.tags.filter { $0.lowercased() == "fall term" } == ["Fall Term"])

        model.sidebarSelection = .tag("Fall Term")
        #expect(Set(model.visibleNotes.map(\.id)) == [a, b])
        model.sidebarSelection = .tag("fall term")   // another case still filters
        #expect(Set(model.visibleNotes.map(\.id)) == [a, b])

        try await model.removeTag("FALL term", from: a)
        #expect(model.sidebarSelection == .tag("fall term"))   // b still has it
        #expect(model.visibleNotes.map(\.id) == [b])
        try await model.removeTag("Fall Term", from: b)
        #expect(!model.tags.contains { $0.lowercased() == "fall term" })   // gone from the sidebar
        #expect(model.sidebarSelection == .allNotes)
    }
}
