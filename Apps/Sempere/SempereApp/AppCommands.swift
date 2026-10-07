import SwiftUI

/// A recent vault, as the File > Open Recent menu lists it.
struct RecentItem: Identifiable, Hashable {
    var id: UUID
    var name: String
}

/// What the focused window offers the menu bar: its state (for enabling) and
/// what to do for a command. Each window publishes one with
/// `focusedSceneValue(\.commandRouter, …)`; `AppCommands` reads the focused one.
struct CommandRouter {
    var context: MenuCommand.Context
    var recents: [RecentItem] = []
    var paletteVisible = true
    var perform: (MenuCommand) -> Void
    var openRecent: (UUID) -> Void = { _ in }
}

private struct CommandRouterKey: FocusedValueKey {
    typealias Value = CommandRouter
}

extension FocusedValues {
    var commandRouter: CommandRouter? {
        get { self[CommandRouterKey.self] }
        set { self[CommandRouterKey.self] = newValue }
    }
}

extension MenuCommand.Shortcut.Modifiers {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

/// The Mac menu bar. Entries come from `MenuLayout`; shortcuts and enabling
/// from `MenuCommand`. Attached to the scene on Mac Catalyst only
/// (`SempereApp`), so the iPad has no new menus.
struct AppCommands: Commands {
    @FocusedValue(\.commandRouter) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            section(MenuLayout.file[0])
            Divider()
            section([.newVault, .openVault])
            Menu("Open Recent") {
                ForEach(router?.recents ?? []) { recent in
                    Button(recent.name) { router?.openRecent(recent.id) }
                }
            }
            .disabled((router?.recents ?? []).isEmpty)
            section([.reopenVault, .closeVault])
            Divider()
            section(MenuLayout.file[2])
        }
        CommandGroup(after: .textEditing) {
            section(MenuLayout.edit[0])
        }
        CommandMenu("Note") {
            sections(MenuLayout.note)
        }
        CommandMenu("Tools") {
            sections(MenuLayout.tools)
        }
        // `CommandGroupPlacement.windowList` is macOS-only (unavailable in the Catalyst SDK), so the
        // two window commands sit at the end of the View menu.
        CommandGroup(after: .toolbar) {
            sections(MenuLayout.view)
            Divider()
            section(MenuLayout.window[0])
        }
    }

    @ViewBuilder
    private func sections(_ groups: [[MenuCommand]]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            section(group)
        }
    }

    @ViewBuilder
    private func section(_ commands: [MenuCommand]) -> some View {
        ForEach(commands, id: \.self) { command in
            item(command)
        }
    }

    @ViewBuilder
    private func item(_ command: MenuCommand) -> some View {
        let enabled = router.map { command.isEnabled(in: $0.context) } ?? (command == .showLibrary || command == .showSettings)
        let title = command == .togglePalette && router?.paletteVisible == true ? String(localized: "Hide Tool Palette") : command.title
        let button = Button(title) { run(command) }.disabled(!enabled)
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut.key == MenuCommand.Shortcut.backspace ? KeyEquivalent.delete : KeyEquivalent(shortcut.key),
                                    modifiers: shortcut.modifiers.eventModifiers)
        } else {
            button
        }
    }

    private func run(_ command: MenuCommand) {
        switch command {
        case .showKeys: openWindow(id: "keys")
        case .showLibrary: openWindow(id: "library")
        case .showSettings: openWindow(id: "settings")
        default: router?.perform(command)
        }
    }
}

/// The commands that act on a note's editor, shared by the library window and
/// the note windows.
@MainActor
enum EditorCommands {
    /// Runs `command` on `editor` and `ui`; false when it is not an editor command.
    @discardableResult
    static func perform(_ command: MenuCommand, editor: NoteEditor?, ui: WindowUI) -> Bool {
        switch command {
        case .changePaper:
            ui.choosingPaper = true
        case .previousPage:
            if let editor { editor.selectPage(editor.pageIndex - 1) }
        case .nextPage:
            if let editor { editor.selectPage(editor.pageIndex + 1) }
        case .addPage:
            if let editor, !editor.isReadOnly { editor.addPage() }
        case .toolPen, .toolMarker, .toolPencil, .toolEraser, .toolLasso:
            if let tool = ToolChoice(command) { editor?.canvasTarget?.select(tool: tool) }
        case .toggleRuler:
            editor?.canvasTarget?.toggleRuler()
        case .togglePalette:
            UserDefaults.standard.set(!ToolPalette.isVisible(), forKey: ToolPalette.visibleKey)
        case .zoomIn:
            editor?.canvasTarget?.zoom(in: true)
        case .zoomOut:
            editor?.canvasTarget?.zoom(in: false)
        case .fitWidth:
            editor?.canvasTarget?.zoomToFit()
        case .actualSize:
            editor?.canvasTarget?.zoomToActualSize()
        default:
            return false
        }
        return true
    }

    /// The part of the menu context that comes from an editor.
    static func fill(_ context: inout MenuCommand.Context, from editor: NoteEditor?) {
        context.canEditNote = editor.map { !$0.isReadOnly } ?? false
        context.hasPage = editor?.currentPage != nil
        context.pageIndex = editor?.pageIndex ?? 0
        context.pageCount = editor?.pages.count ?? 0
    }
}

/// Per-window UI state that menu commands set: the sheets and alerts of the
/// note actions. Each window has its own, so a command opens its sheet in the
/// window it was chosen in.
@MainActor
@Observable
final class WindowUI {
    /// Identifies the window (`AppModel.canvasWindow`).
    let id = UUID()
    var creatingNote = false
    /// The note being renamed.
    var renameNoteID: UUID?
    /// The note whose tags are being edited.
    var tagsNoteID: UUID?
    /// The note a version is being saved of (the Save Version alert).
    var saveVersionNoteID: UUID?
    var choosingPaper = false
    var searchPresented = false
    /// A PDF being imported that needs its password (`PDFImportRequest`).
    var pdfPassword: PDFImportRequest?
    /// The file importer for a PDF to import as a new note.
    var importingPDF = false
}
