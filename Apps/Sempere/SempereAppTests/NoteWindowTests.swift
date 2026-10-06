import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// One note per window (Mac): window editors, claims, the PDF a note drags out
/// as, and restoring the library window's selection.
@MainActor
struct NoteWindowTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> (AppModel, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return (model, url)
    }

    @Test func aWindowTakesTheNoteFromTheLibraryPaneAndGivesItBack() async throws {
        let (model, _) = try await Self.unlockedModel()
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        #expect(model.editor?.noteID == Self.lecture)

        await model.claimNote(Self.lecture)
        #expect(model.editor == nil, "the pane's editor was closed: one editor per note")
        await model.showSelectedNote()
        #expect(model.editor == nil, "a claimed note is not opened by the pane")

        let window = try await model.openWindowNote(Self.lecture)
        #expect(window.noteID == Self.lecture)
        #expect(!window.isReadOnly)
        let again = try await model.openWindowNote(Self.lecture)
        #expect(again === window, "a second request for the same window shares its editor")

        await model.releaseNote(Self.lecture)
        #expect(model.windowEditors.isEmpty)
        #expect(!model.windowClaims.contains(Self.lecture))
        await model.showSelectedNote()
        #expect(model.editor?.noteID == Self.lecture)
    }

    @Test func twoWindowsHoldTwoNotesAndShareTheClock() async throws {
        let (model, url) = try await Self.unlockedModel()
        let id = try await model.createNote(title: "Second", paper: .blank, notebook: nil)
        await model.claimNote(Self.lecture)
        await model.claimNote(id)
        let a = try await model.openWindowNote(Self.lecture)
        let b = try await model.openWindowNote(id)
        #expect(a !== b)
        a.addPage()
        b.addPage()
        await a.flush()
        await b.flush()
        let vault = try Vault.open(at: url, identities: model.unlockIdentities)
        let device = try model.deviceClockForWriting().device
        let first = try vault.loadNote(Self.lecture).revisions.filter { $0.device == device }
        let second = try vault.loadNote(id).revisions.filter { $0.device == device }
        #expect(first.count == 1)
        #expect(second.count >= 1)
        let state = try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions)
        #expect(state.pages.count == 3)
    }

    @Test func aWindowForANoteThatIsNotThereFails() async throws {
        let (model, _) = try await Self.unlockedModel()
        await #expect(throws: AppModel.ModelError.noteNotFound) { _ = try await model.openWindowNote(UUID()) }
    }

    @Test func aWindowNeedsAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.openWindowNote(Self.lecture) }
    }

    @Test func closingTheVaultSavesAndDropsEveryWindowEditor() async throws {
        let (model, url) = try await Self.unlockedModel()
        await model.claimNote(Self.lecture)
        let window = try await model.openWindowNote(Self.lecture)
        window.addPage()
        let identities = model.unlockIdentities
        model.close()
        #expect(model.windowEditors.isEmpty)
        #expect(model.windowClaims.isEmpty)
        await model.closingEditor?.value   // the close saves the pending page
        let vault = try Vault.open(at: url, identities: identities)
        #expect(try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions).pages.count == 3)
    }

    @Test func deletingANoteReopensItsWindowReadOnly() async throws {
        let (model, _) = try await Self.unlockedModel()
        await model.claimNote(Self.lecture)
        _ = try await model.openWindowNote(Self.lecture)
        try await model.deleteNote(Self.lecture)
        #expect(model.windowEditors[Self.lecture]?.isReadOnly == true)
        try await model.restoreNote(Self.lecture)
        #expect(model.windowEditors[Self.lecture]?.isReadOnly == false)
    }

    // MARK: - Restoring the selection

    @Test func aSavedSelectionIsAppliedWhenItsNoteAndTagStillExist() async throws {
        let (model, _) = try await Self.unlockedModel()
        let vault = try #require(model.vault?.vaultId)
        let saved = RestorableSelection(sidebar: .tag("fixture"), note: Self.lecture, vault: vault)
        #expect(model.restore(saved))
        #expect(model.sidebarSelection == .tag("fixture"))
        #expect(model.selectedNoteID == Self.lecture)
    }

    @Test func aSavedSelectionFallsBackWhenItsPartsAreGone() async throws {
        let (model, _) = try await Self.unlockedModel()
        let vault = try #require(model.vault?.vaultId)
        #expect(model.restore(RestorableSelection(sidebar: .tag("gone"), note: UUID(), vault: vault)))
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.selectedNoteID == nil)
        #expect(model.restore(RestorableSelection(sidebar: .notebook("Nowhere/Here"), note: nil, vault: vault)))
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.restore(RestorableSelection(sidebar: .deleted, note: AppModelTests.deleted, vault: vault)))
        #expect(model.sidebarSelection == .deleted)
        #expect(model.selectedNoteID == AppModelTests.deleted)
    }

    @Test func aSelectionOfAnotherVaultIsIgnored() async throws {
        let (model, _) = try await Self.unlockedModel()
        #expect(!model.restore(RestorableSelection(sidebar: .deleted, note: Self.lecture, vault: UUID())))
        #expect(model.sidebarSelection == .allNotes)
        #expect(model.selectedNoteID == nil)
        let closed = AppModel(deviceStateURL: TS.deviceStateURL())
        #expect(!closed.restore(RestorableSelection(sidebar: .allNotes, note: nil, vault: nil)))
    }

    // MARK: - PDF export (drag to Finder)

    @Test func exportWritesANamedPDFOfTheNote() async throws {
        let (model, _) = try await Self.unlockedModel()
        let url = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(url.lastPathComponent == "Fixture lecture.pdf")
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF-".utf8)))
        #expect(data.count > 500)
    }

    @Test func exportsOfOneTitleDoNotCollide() async throws {
        let (model, _) = try await Self.unlockedModel()
        let a = try await model.exportPDF(noteID: Self.lecture)
        let b = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(a != b)
        #expect(a.lastPathComponent == b.lastPathComponent)
    }

    @Test func exportIncludesInkNotYetSaved() async throws {
        let (model, _) = try await Self.unlockedModel()
        let before = try await model.exportPDF(noteID: Self.lecture)
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        editor.addPage()
        let after = try await model.exportPDF(noteID: Self.lecture)
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
        #expect(try Data(contentsOf: after).count > (try Data(contentsOf: before)).count, "the new page is in the PDF")
    }

    @Test func exportNeedsAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.exportPDF(noteID: Self.lecture) }
    }

    @Test func oldExportsArePurgedAndNewOnesKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("purge-\(UUID().uuidString)")
        let rendered = NotePDFExport.Rendered(title: "T", pdf: Data("%PDF-1.4".utf8))
        let url = try NotePDFExport.write(rendered, in: folder)
        NotePDFExport.purge(in: folder, olderThan: 600)
        #expect(FileManager.default.fileExists(atPath: url.path))
        NotePDFExport.purge(in: folder, olderThan: 600, now: Date().addingTimeInterval(3600))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: folder)
    }
}
