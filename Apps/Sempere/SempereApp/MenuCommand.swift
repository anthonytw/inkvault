import Foundation

/// Every command of the Mac menu bar, in one type. Menus (`AppCommands`),
/// shortcuts and enabling all derive from this list, so a feature that adds a
/// menu entry (share and export, history) adds a case here and nothing else
/// has to agree with it by hand: `MenuCommandTests` checks that no two
/// commands share a shortcut.
///
/// Pure Foundation: the SwiftUI side converts `Shortcut` to a
/// `KeyboardShortcut` (`AppCommands.swift`).
enum MenuCommand: String, CaseIterable, Sendable {
    // File
    case newNote, openNoteInWindow, newVault, openVault, reopenVault, closeVault, reloadVault
    case importPDF, importNotability, insertPDFPages, insertPhoto, exportNotes
    // Note
    case renameNote, editTags, changePaper, saveVersion, deleteNote, restoreNote
    case previousPage, nextPage, addPage
    // Edit
    case find, undo, redo
    // Tools
    case toolPen, toolMarker, toolPencil, toolEraser, toolLasso, toggleRuler, togglePalette
    // View
    case zoomIn, zoomOut, fitWidth, actualSize, toggleNoteList
    // Window
    case showLibrary, showKeys, showSettings

    /// A key and its modifiers. `key` is the character the key types.
    struct Shortcut: Hashable, Sendable {
        struct Modifiers: OptionSet, Hashable, Sendable {
            let rawValue: Int
            static let command = Modifiers(rawValue: 1)
            static let shift = Modifiers(rawValue: 2)
            static let option = Modifiers(rawValue: 4)
            static let control = Modifiers(rawValue: 8)
        }

        var key: Character
        var modifiers: Modifiers

        init(_ key: Character, _ modifiers: Modifiers = [.command]) {
            self.key = key
            self.modifiers = modifiers
        }

        /// ⌫, the delete key (`KeyEquivalent.delete`).
        static let backspace: Character = "\u{7F}"
    }

    /// Commands whose shortcut UIKit's own menu bar already uses on a Mac
    /// (⌘O for "Open…", ⌘F for "Find…", ⌘, for the app menu's "Settings…").
    /// UIKit refuses a SwiftUI menu group holding such a shortcut, and with it
    /// every other command of the group (TestFlight build 6: the File and Edit
    /// commands were missing), so these are not SwiftUI commands: `MacMenus`
    /// turns UIKit's own items into them. UIKit's Settings… opened Catalyst's
    /// generated preferences pane (touch alternatives only), not the app's
    /// settings (TestFlight build 7).
    static let nativeOnMac: [MenuCommand] = [.openVault, .find, .showSettings]

    /// Who handles the command.
    enum Provider: Sendable {
        /// The app, through `AppCommands`.
        case app
        /// UIKit's responder chain (Edit > Undo and Redo act on the focused
        /// canvas's undo manager, and on text fields while one is being edited).
        /// Listed so the shortcut table is complete, never added as a menu item.
        case system
    }

    var provider: Provider {
        switch self {
        case .undo, .redo: return .system
        default: return .app
        }
    }

    var title: String {
        switch self {
        case .newNote: return "New Note…"
        case .openNoteInWindow: return "Open Note in New Window"
        case .newVault: return "New Vault…"
        case .openVault: return "Open Vault…"
        case .reopenVault: return "Reopen Last Vault"
        case .closeVault: return "Close Vault"
        case .reloadVault: return "Reload Vault"
        case .importPDF: return "Import PDF as New Note…"
        case .importNotability: return "Import from Notability…"
        case .insertPDFPages: return "Insert PDF Pages…"
        case .insertPhoto: return "Insert Photo…"
        case .exportNotes: return "Export…"
        case .renameNote: return "Rename Note…"
        case .editTags: return "Edit Tags…"
        case .changePaper: return "Paper…"
        case .saveVersion: return "Save Version…"
        case .deleteNote: return "Move to Recently Deleted"
        case .restoreNote: return "Restore Note"
        case .previousPage: return "Previous Page"
        case .nextPage: return "Next Page"
        case .addPage: return "Add Page"
        case .find: return "Find Notes"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .toolPen: return "Pen"
        case .toolMarker: return "Marker"
        case .toolPencil: return "Pencil"
        case .toolEraser: return "Eraser"
        case .toolLasso: return "Lasso"
        case .toggleRuler: return "Ruler"
        case .togglePalette: return "Show Tool Palette"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .fitWidth: return "Fit Page Width"
        case .actualSize: return "Actual Size"
        case .toggleNoteList: return "Hide or Show Note List"
        case .showLibrary: return "Library"
        case .showKeys: return "Vault Keys"
        case .showSettings: return "Settings…"
        }
    }

    /// The keyboard shortcut, if any. Plain keys are never used: they would
    /// take typing away from the title and tag fields.
    var shortcut: Shortcut? {
        let cmd: Shortcut.Modifiers = [.command]
        let shift: Shortcut.Modifiers = [.command, .shift]
        let option: Shortcut.Modifiers = [.command, .option]
        switch self {
        case .newNote: return Shortcut("n", cmd)
        case .openNoteInWindow: return Shortcut("n", option)
        case .newVault: return Shortcut("n", shift)
        case .openVault: return Shortcut("o", cmd)
        case .reopenVault: return Shortcut("t", shift)
        case .closeVault: return Shortcut("w", shift)
        case .reloadVault: return Shortcut("r", cmd)
        // ⌘I is UIKit's Italic (Format menu); ⌘E its "Use Selection for Find".
        case .importPDF: return Shortcut("i", shift)
        case .importNotability: return nil
        case .insertPDFPages: return nil
        case .insertPhoto: return Shortcut("i", option)
        case .exportNotes: return Shortcut("e", shift)
        case .renameNote: return Shortcut("r", shift)
        case .editTags: return Shortcut("t", option)
        case .changePaper: return Shortcut("p", option)
        case .saveVersion: return Shortcut("s", option)
        case .deleteNote: return Shortcut(Shortcut.backspace, cmd)
        case .restoreNote: return nil
        case .previousPage: return Shortcut("[", cmd)
        case .nextPage: return Shortcut("]", cmd)
        case .addPage: return Shortcut("a", shift)
        case .find: return Shortcut("f", cmd)
        case .undo: return Shortcut("z", cmd)
        case .redo: return Shortcut("z", shift)
        case .toolPen: return Shortcut("1", option)
        case .toolMarker: return Shortcut("2", option)
        case .toolPencil: return Shortcut("3", option)
        case .toolEraser: return Shortcut("4", option)
        case .toolLasso: return Shortcut("5", option)
        case .toggleRuler: return Shortcut("r", option)
        case .togglePalette: return Shortcut("p", shift)
        case .zoomIn: return Shortcut("=", cmd)
        case .zoomOut: return Shortcut("-", cmd)
        case .fitWidth: return Shortcut("0", cmd)
        case .actualSize: return Shortcut("1", cmd)
        case .toggleNoteList: return Shortcut("l", option)
        case .showLibrary: return Shortcut("0", option)
        case .showKeys: return Shortcut("k", option)
        case .showSettings: return Shortcut(",", cmd)
        }
    }

    /// What the focused window is showing, as far as menu enabling goes.
    struct Context: Equatable, Sendable {
        enum Vault: Equatable, Sendable { case none, locked, migrating, unlocked }
        enum Window: Equatable, Sendable { case library, note, other }

        var window: Window = .library
        var vault: Vault = .none
        /// A note is selected (library) or shown (note window).
        var hasNote = false
        var noteDeleted = false
        /// A note is open on a canvas that accepts input.
        var canEditNote = false
        /// The open note is pageless (one infinite page): PDF pages cannot be inserted.
        var notePageless = false
        /// The vault opened read-only (a newer format version, format.md §7.3).
        var vaultReadOnly = false
        /// The notes File > Export acts on (`CommandRouter.exportIDs`) are not empty.
        var hasExportTargets = false
        /// The canvas has a page to show.
        var hasPage = false
        var pageIndex = 0
        var pageCount = 0
        /// A vault was opened before and can be reopened.
        var hasRecents = false
        /// A library window exists (View > Library opens one when not).
        var libraryWindowOpen = true
        /// A text field of the window may have focus (search, rename, tags):
        /// ⌘⌫ there means "delete to the start of the line", and a menu key
        /// equivalent would win over it on the Mac.
        var editingText = false
        /// The note list is in the window (library windows only).
        var hasNoteList: Bool { window == .library }
    }

    /// Whether the command is available in `context`.
    func isEnabled(in context: Context) -> Bool {
        let unlocked = context.vault == .unlocked
        switch self {
        // The vault pickers, the note list and the sheets they open live in the library window.
        case .openVault, .newVault: return context.hasNoteList
        case .reopenVault: return context.hasNoteList && context.vault == .none && context.hasRecents
        case .closeVault: return context.vault != .none
        case .reloadVault: return unlocked && context.hasNoteList
        case .newNote: return unlocked && context.hasNoteList
        case .openNoteInWindow: return unlocked && context.hasNoteList && context.hasNote && !context.noteDeleted
        case .renameNote, .editTags, .saveVersion: return unlocked && context.hasNote && !context.noteDeleted
        case .deleteNote: return unlocked && context.hasNote && !context.noteDeleted && !context.editingText
        case .restoreNote: return unlocked && context.hasNote && context.noteDeleted
        // The importers and their sheets are per window (`WindowSheets`): any window with a vault.
        case .importPDF, .importNotability: return unlocked && !context.vaultReadOnly && context.window != .other
        // The Insert menu's own rule (`InsertMenu`): an editable note with a page; PDF pages need a paged note.
        case .insertPhoto: return context.canEditNote && context.hasPage
        case .insertPDFPages: return context.canEditNote && context.hasPage && !context.notePageless
        case .exportNotes: return unlocked && context.hasExportTargets
        case .changePaper: return context.canEditNote && context.hasPage
        case .addPage: return context.canEditNote
        case .previousPage: return context.hasPage && context.pageIndex > 0
        case .nextPage: return context.hasPage && context.pageIndex + 1 < context.pageCount
        case .find, .toggleNoteList: return unlocked && context.hasNoteList
        case .undo, .redo: return context.canEditNote
        case .toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso, .toggleRuler, .togglePalette:
            return context.canEditNote
        case .zoomIn, .zoomOut, .fitWidth, .actualSize: return context.hasPage
        case .showLibrary: return !context.libraryWindowOpen
        case .showKeys: return unlocked
        // Device settings need no vault.
        case .showSettings: return true
        }
    }
}

/// The menu bar's groups, in order, with their commands. The only place the
/// layout is written down (`AppCommands` walks it).
enum MenuLayout {
    static let file: [[MenuCommand]] = [
        [.newNote, .openNoteInWindow],
        [.newVault, .openVault, .reopenVault, .closeVault],
        [.importPDF, .importNotability],
        [.insertPDFPages, .insertPhoto],
        [.exportNotes],
        [.reloadVault],
    ]
    static let note: [[MenuCommand]] = [
        [.renameNote, .editTags, .changePaper],
        [.saveVersion],
        [.previousPage, .nextPage, .addPage],
        [.deleteNote, .restoreNote],
    ]
    static let tools: [[MenuCommand]] = [
        [.toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso],
        [.toggleRuler, .togglePalette],
    ]
    static let view: [[MenuCommand]] = [
        [.zoomIn, .zoomOut, .fitWidth, .actualSize],
        [.toggleNoteList],
    ]
    static let window: [[MenuCommand]] = [[.showLibrary, .showKeys, .showSettings]]
    /// Edit > Find (the system's Undo and Redo stay where UIKit puts them).
    static let edit: [[MenuCommand]] = [[.find]]

    /// Every command a menu shows, in order.
    static var all: [MenuCommand] {
        (file + edit + note + tools + view + window).flatMap { $0 }
    }
}
