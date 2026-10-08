import Sempere
import SwiftUI

/// One note in a window of its own (Mac): its canvas, title and tags. The
/// window is opened with a `NoteWindowValue`, which SwiftUI saves and opens
/// again at the next launch; the vault has to be open and unlocked first
/// (the library window does that, and is brought up if no window is).
struct NoteWindowView: View {
    let value: NoteWindowValue
    @Environment(AppModel.self) private var model
    @Environment(VaultLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
    @State private var ui = WindowUI()
    @State private var failure: String?

    /// The model's editor for this note, never a copy kept here: a delete,
    /// restore or key change replaces or closes it, and the window must
    /// follow (a kept copy would go on taking ink for a closed editor).
    private var editor: NoteEditor? {
        guard let open = model.windowEditors[value.noteID], !open.isShutDown else { return nil }
        return open
    }
    private var note: NoteSummary? { model.notes.first { $0.id == value.noteID } }
    private var otherVault: Bool { model.phase == .unlocked && model.vault?.vaultId != value.vaultID }
    private var ready: Bool { model.phase == .unlocked && !otherVault && note != nil }

    private struct LoadKey: Hashable {
        var ready: Bool
        var epoch: Int
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(note.map { NoteTitle.display($0.title) } ?? "Note")
                .toolbar {
                    if let note {
                        ToolbarItem(placement: .secondaryAction) {
                            Button("Rename…", systemImage: "pencil") { ui.renameNoteID = note.id }
                                .help("Rename the note")
                        }
                        ToolbarItem(placement: .secondaryAction) {
                            Button("Save Version…", systemImage: "bookmark") { ui.saveVersionNoteID = note.id }
                                .disabled(note.deleted)
                                .help("Save this version of the note under a name; saved versions are never thinned")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Tags", systemImage: note.tags.isEmpty ? "tag" : "tag.fill") { ui.tagsNoteID = note.id }
                                .help("Edit the note's tags")
                        }
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteWindow")
        .environment(ui)
        .windowSheets(ui)
        .focusedSceneValue(\.commandRouter, router)
        .menuRouter(router)
        // A file opened with Sempere while this window is in front: the same as in the library window.
        .onOpenURL { url in Task { await model.handleOpened(url, library: library) } }
        .task(id: LoadKey(ready: ready, epoch: model.keyEpoch)) { await load() }
        .task {
            // Restored without the library window: bring it up to open and unlock the vault.
            try? await Task.sleep(for: .seconds(1))
            if model.phase == .noVault, model.shouldOpenLibraryWindow() { openWindow(id: "library") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let editor { Task { await editor.flush() } }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .noVault { dismissWindow(id: NoteWindowValue.sceneID, value: value) }
        }
        .onDisappear {
            let id = value.noteID
            Task { await model.releaseNote(id) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let editor, ready {
            EditorView(editor: editor)
        } else if otherVault {
            ContentUnavailableView {
                Label("Another Vault Is Open", systemImage: "lock")
            } description: {
                Text("This window belongs to a note in a different vault. Close it, or open that vault again.")
            } actions: {
                Button("Close Window") { dismissWindow(id: NoteWindowValue.sceneID, value: value) }
            }
        } else if let failure {
            ContentUnavailableView {
                Label("Could Not Open Note", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if model.phase == .noVault || model.phase == .locked {
            ContentUnavailableView {
                Label("Waiting for the Vault", systemImage: "lock")
            } description: {
                Text("Open and unlock the vault in the library window.")
            } actions: {
                Button("Show Library") { if model.shouldOpenLibraryWindow() { openWindow(id: "library") } }
            }
        } else if ready || model.isBusy {
            ProgressView("Opening…")
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "questionmark.folder",
                                   description: Text("That note is no longer in the vault."))
        }
    }

    private func load() async {
        failure = nil
        guard ready else { return }
        await model.claimNote(value.noteID)
        do {
            _ = try await model.openWindowNote(value.noteID)
        } catch is CancellationError {
        } catch {
            failure = "\(error)"
        }
    }

    private var router: CommandRouter {
        var context = MenuCommand.Context()
        context.window = .note
        context.vault = model.phase == .unlocked ? .unlocked : (model.phase == .noVault ? .none : .locked)
        context.hasNote = note != nil
        context.noteDeleted = note?.deleted ?? false
        context.libraryWindowOpen = model.libraryWindowCount > 0
        context.hasRecents = !library.recents.isEmpty
        context.editingText = ui.renameNoteID != nil || ui.tagsNoteID != nil || ui.saveVersionNoteID != nil
        EditorCommands.fill(&context, from: editor)
        let exportIDs = note.map { [$0.id] } ?? []
        WindowCommands.fill(&context, model: model, exportIDs: exportIDs)
        return CommandRouter(context: context, recents: library.recents.map { RecentItem(id: $0.id, name: $0.name) },
                             paletteVisible: paletteVisible, exportIDs: exportIDs, windowID: ui.id) { command in
            guard !EditorCommands.perform(command, editor: editor, ui: ui) else { return }
            guard !WindowCommands.perform(command, model: model, ui: ui, exportIDs: exportIDs) else { return }
            switch command {
            case .renameNote: ui.renameNoteID = value.noteID
            case .editTags: ui.tagsNoteID = value.noteID
            case .saveVersion: ui.saveVersionNoteID = value.noteID
            case .deleteNote:
                let id = value.noteID
                Task { await model.report { try await model.deleteNote(id) } }
            case .restoreNote:
                let id = value.noteID
                Task { await model.report { try await model.restoreNote(id) } }
            case .closeVault: model.close()
            default: break
            }
        }
    }
}
