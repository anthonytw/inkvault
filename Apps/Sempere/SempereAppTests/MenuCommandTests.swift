import Foundation
import Testing
@testable import SempereApp

/// The Mac menu command list: one type for every command, no clashing shortcuts.
struct MenuCommandTests {
    @Test func noTwoCommandsShareAShortcut() {
        var seen: [MenuCommand.Shortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            if let other = seen[shortcut] { Issue.record("\(command) and \(other) share \(shortcut)") }
            seen[shortcut] = command
        }
    }

    @Test func shortcutsAlwaysUseAModifierSoTypingIsNeverTaken() {
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(shortcut.modifiers.contains(.command), "\(command) needs ⌘")
        }
    }

    @Test func everyAppCommandIsInTheMenuLayoutExactlyOnce() {
        let laidOut = MenuLayout.all
        #expect(Set(laidOut).count == laidOut.count, "a command is listed twice")
        for command in MenuCommand.allCases where command.provider == .app {
            #expect(laidOut.contains(command), "\(command) is in no menu")
        }
        for command in MenuCommand.allCases where command.provider == .system {
            #expect(!laidOut.contains(command), "\(command) is the system's, not an app menu item")
        }
    }

    @Test func systemEditCommandsKeepTheStandardShortcuts() {
        #expect(MenuCommand.undo.provider == .system)
        #expect(MenuCommand.undo.shortcut == MenuCommand.Shortcut("z", [.command]))
        #expect(MenuCommand.redo.shortcut == MenuCommand.Shortcut("z", [.command, .shift]))
    }

    @Test func everyCommandHasATitle() {
        for command in MenuCommand.allCases { #expect(!command.title.isEmpty) }
    }

    @Test func nothingNeedingAVaultIsEnabledWithoutOne() {
        let none = MenuCommand.Context(window: .library, vault: .none)
        let needsUnlocked: [MenuCommand] = [.newNote, .openNoteInWindow, .renameNote, .editTags, .deleteNote, .restoreNote,
                                            .find, .reloadVault, .showKeys, .toolPen, .zoomIn, .changePaper, .addPage]
        for command in needsUnlocked { #expect(!command.isEnabled(in: none), "\(command)") }
        #expect(MenuCommand.openVault.isEnabled(in: none))
        #expect(MenuCommand.newVault.isEnabled(in: none))
        #expect(!MenuCommand.closeVault.isEnabled(in: none))
    }

    @Test func reopenNeedsAClosedVaultAndARecentOne() {
        var c = MenuCommand.Context(window: .library, vault: .none)
        #expect(!MenuCommand.reopenVault.isEnabled(in: c))
        c.hasRecents = true
        #expect(MenuCommand.reopenVault.isEnabled(in: c))
        c.vault = .unlocked
        #expect(!MenuCommand.reopenVault.isEnabled(in: c))
        #expect(MenuCommand.closeVault.isEnabled(in: c))
        c.vault = .locked
        #expect(MenuCommand.closeVault.isEnabled(in: c))
    }

    @Test func noteCommandsFollowTheSelectedNote() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.renameNote.isEnabled(in: c))
        c.hasNote = true
        #expect(MenuCommand.renameNote.isEnabled(in: c))
        #expect(MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.openNoteInWindow.isEnabled(in: c))
        #expect(!MenuCommand.restoreNote.isEnabled(in: c))
        c.noteDeleted = true
        #expect(!MenuCommand.renameNote.isEnabled(in: c))
        #expect(!MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.restoreNote.isEnabled(in: c))
    }

    /// ⌘⌫ in the search field (or a rename or tag field) deletes text, never the note.
    @Test func deleteIsOffWhileATextFieldMayHaveFocus() {
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        c.hasNote = true
        #expect(MenuCommand.deleteNote.isEnabled(in: c))
        c.editingText = true
        #expect(!MenuCommand.deleteNote.isEnabled(in: c))
        #expect(MenuCommand.renameNote.isEnabled(in: c))
    }

    @Test func canvasCommandsNeedAnEditableCanvas() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        for command in [MenuCommand.toolPen, .toolEraser, .toggleRuler, .togglePalette, .addPage, .changePaper] {
            #expect(!command.isEnabled(in: c), "\(command)")
        }
        c.hasPage = true
        c.pageCount = 3
        c.pageIndex = 0
        #expect(MenuCommand.zoomIn.isEnabled(in: c))
        #expect(!MenuCommand.toolPen.isEnabled(in: c), "read-only: zoom works, tools do not")
        c.canEditNote = true
        for command in [MenuCommand.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso, .toggleRuler, .togglePalette,
                        .addPage, .changePaper, .undo, .redo] {
            #expect(command.isEnabled(in: c), "\(command)")
        }
        #expect(!MenuCommand.previousPage.isEnabled(in: c))
        #expect(MenuCommand.nextPage.isEnabled(in: c))
        c.pageIndex = 2
        #expect(MenuCommand.previousPage.isEnabled(in: c))
        #expect(!MenuCommand.nextPage.isEnabled(in: c))
    }

    /// GA-13: item commands act on a selected item of an editable note, and never while a text field may
    /// have focus (⌥⌘⌫ would otherwise delete the item instead of a word).
    @Test func itemCommandsNeedASelectedItemOnAnEditableNote() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        let items: [MenuCommand] = [.duplicateItem, .bringItemToFront, .deleteItem]
        for command in items { #expect(!command.isEnabled(in: c), "\(command): nothing selected") }
        c.hasItemSelection = true
        for command in items { #expect(!command.isEnabled(in: c), "\(command): read-only") }
        c.canEditNote = true
        for command in items { #expect(command.isEnabled(in: c), "\(command)") }
        c.editingText = true
        #expect(MenuCommand.duplicateItem.isEnabled(in: c))
        #expect(!MenuCommand.deleteItem.isEnabled(in: c))
    }

    /// GA-13: Start/Stop Recording needs an editable page, and stays on while a recording runs.
    @Test func recordingCommandStartsOnAnEditablePageAndStopsWhileRecording() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        #expect(!MenuCommand.toggleRecording.isEnabled(in: c))
        c.hasPage = true
        #expect(!MenuCommand.toggleRecording.isEnabled(in: c), "read-only")
        c.canEditNote = true
        #expect(MenuCommand.toggleRecording.isEnabled(in: c))
        c.isRecording = true
        c.canEditNote = false
        #expect(MenuCommand.toggleRecording.isEnabled(in: c), "a running recording can always be stopped")
    }

    @Test func itemAndRecordingShortcuts() throws {
        #expect(MenuCommand.duplicateItem.shortcut == MenuCommand.Shortcut("d", [.command]))
        #expect(MenuCommand.bringItemToFront.shortcut == MenuCommand.Shortcut("f", [.command, .option, .shift]))
        #expect(MenuCommand.deleteItem.shortcut == MenuCommand.Shortcut(MenuCommand.Shortcut.backspace, [.command, .option]))
        #expect(MenuCommand.toggleRecording.shortcut == MenuCommand.Shortcut("m", [.command, .shift]))
        #expect(MenuCommand.deleteNote.shortcut != MenuCommand.deleteItem.shortcut, "⌘⌫ stays the note's")
        // UIKit's own menus use these: the Mac menu bar starts from them (CLAUDE.md "The Mac menu bar").
        let uikit: Set<MenuCommand.Shortcut> = [.init("m"), .init("w"), .init("h"), .init("q"), .init("p"), .init("a"),
                                                .init("c"), .init("x"), .init("v"), .init("b"), .init("i"), .init("u"),
                                                .init("g"), .init("e"), .init("j"), .init("t")]
        for command in [MenuCommand.duplicateItem, .bringItemToFront, .deleteItem, .toggleRecording] {
            #expect(!uikit.contains(try #require(command.shortcut)), "\(command)")
        }
    }

    @Test func libraryOnlyCommandsAreOffInANoteWindow() {
        let note = MenuCommand.Context(window: .note, vault: .unlocked, hasNote: true)
        for command in [MenuCommand.newNote, .find, .toggleNoteList, .openVault, .newVault, .reloadVault, .openNoteInWindow] {
            #expect(!command.isEnabled(in: note), "\(command)")
        }
        #expect(MenuCommand.closeVault.isEnabled(in: note))
        #expect(MenuCommand.renameNote.isEnabled(in: note))
        #expect(MenuCommand.showKeys.isEnabled(in: note))
    }

    @Test func libraryWindowCommandOpensOnlyWhenNoneIsOpen() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked)
        c.libraryWindowOpen = true
        #expect(!MenuCommand.showLibrary.isEnabled(in: c))
        c.libraryWindowOpen = false
        #expect(MenuCommand.showLibrary.isEnabled(in: c))
    }

    @Test func toolCommandsMapToTools() {
        #expect(ToolChoice(.toolPen) == .pen)
        #expect(ToolChoice(.toolLasso) == .lasso)
        #expect(ToolChoice(.zoomIn) == nil)
        let mapped = MenuCommand.allCases.compactMap { ToolChoice($0) }
        #expect(Set(mapped) == Set(ToolChoice.allCases))
    }
}
