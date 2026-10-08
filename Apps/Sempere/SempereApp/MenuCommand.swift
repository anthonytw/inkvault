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
    case bulkExport
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
    /// (⌘O for "Open…", ⌘F for "Find…"). UIKit refuses a SwiftUI menu group
    /// holding such a shortcut, and with it every other command of the group
    /// (TestFlight build 6: the File and Edit commands were missing), so these
    /// are not SwiftUI commands: `MacMenus` turns UIKit's own items into them.
    static let nativeOnMac: [MenuCommand] = [.openVault, .find]

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
        case .newNote: return String(localized: "New Note…")
        case .openNoteInWindow: return String(localized: "Open Note in New Window")
        case .newVault: return String(localized: "New Vault…")
        case .openVault: return String(localized: "Open Vault…")
        case .reopenVault: return String(localized: "Reopen Last Vault")
        case .closeVault: return String(localized: "Close Vault")
        case .reloadVault: return String(localized: "Reload Vault")
        case .bulkExport: return String(localized: "Export Notes…")
        case .renameNote: return String(localized: "Rename Note…")
        case .editTags: return String(localized: "Edit Tags…")
        case .changePaper: return String(localized: "Paper…", comment: "Note menu: choose the page's paper")
        case .saveVersion: return String(localized: "Save Version…")
        case .deleteNote: return String(localized: "Move to Recently Deleted")
        case .restoreNote: return String(localized: "Restore Note")
        case .previousPage: return String(localized: "Previous Page")
        case .nextPage: return String(localized: "Next Page")
        case .addPage: return String(localized: "Add Page")
        case .find: return String(localized: "Find Notes", comment: "Edit menu: search the notes")
        case .undo: return String(localized: "Undo", comment: "Edit menu: undo")
        case .redo: return String(localized: "Redo", comment: "Edit menu: redo")
        case .toolPen: return String(localized: "Pen", comment: "Tools menu: select the pen")
        case .toolMarker: return String(localized: "Marker", comment: "Tools menu: select the marker")
        case .toolPencil: return String(localized: "Pencil", comment: "Tools menu: select the pencil tool")
        case .toolEraser: return String(localized: "Eraser", comment: "Tools menu: select the eraser")
        case .toolLasso: return String(localized: "Lasso", comment: "Tools menu: select the lasso")
        case .toggleRuler: return String(localized: "Ruler", comment: "Tools menu: show or hide the ruler")
        case .togglePalette: return String(localized: "Show Tool Palette")
        case .zoomIn: return String(localized: "Zoom In", comment: "View menu")
        case .zoomOut: return String(localized: "Zoom Out", comment: "View menu")
        case .fitWidth: return String(localized: "Fit Page Width")
        case .actualSize: return String(localized: "Actual Size", comment: "View menu: zoom to 100%")
        case .toggleNoteList: return String(localized: "Hide or Show Note List")
        case .showLibrary: return String(localized: "Library", comment: "View menu: show the library window")
        case .showKeys: return String(localized: "Vault Keys", comment: "View menu: open the vault keys window")
        case .showSettings: return String(localized: "Settings…", comment: "View menu: open Settings")
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
        case .bulkExport: return nil
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
        // The ticked notes, the sidebar's notebook or the vault of the library window.
        case .bulkExport: return unlocked && context.hasNoteList
        case .newNote: return unlocked && context.hasNoteList
        case .openNoteInWindow: return unlocked && context.hasNoteList && context.hasNote && !context.noteDeleted
        case .renameNote, .editTags, .saveVersion: return unlocked && context.hasNote && !context.noteDeleted
        case .deleteNote: return unlocked && context.hasNote && !context.noteDeleted && !context.editingText
        case .restoreNote: return unlocked && context.hasNote && context.noteDeleted
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
        [.reloadVault],
        [.bulkExport],
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
