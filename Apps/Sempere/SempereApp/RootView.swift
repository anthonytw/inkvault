import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The welcome screen until a vault is open, then three columns: sidebar
/// (notebooks, tags), note list, and the note itself.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(VaultLibrary.self) private var library
    @Environment(RememberedKeys.self) private var keys
    @State private var pickingVault = false
    @State private var creatingVault = false
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    /// Set when a failed reopen should end in the folder picker.
    @State private var pickAfterAlert = false
    @State private var triedAutoOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = false
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
    @Environment(\.openWindow) private var openWindow
    @State private var ui = WindowUI()
    /// The library window's selection, restored with the scene (Mac only).
    @SceneStorage(RestorableSelection.key) private var storedSelection = ""
    /// The vault whose saved selection was applied (or found missing); until
    /// then nothing is saved, so the first selections do not overwrite it.
    @State private var restoredVault: UUID?

    /// The stack column an iPhone shows (`CompactNavigation`); the other devices ignore it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// The split view's columns. An iPhone leaves them to the system (a stack when
    /// compact, columns in a wide landscape) and never stores a hidden list.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { Platform.isPhone ? .automatic : ColumnLayout.visibility(from: storedColumns) },
                set: { if !Platform.isPhone { storedColumns = ColumnLayout.stored($0) } })
    }

    /// The window: its content, then what the Mac menus and scene restoration need.
    /// Two properties, so the compiler checks two shorter modifier chains.
    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("libraryWindow")
            .environment(ui)
            .windowSheets(ui)
            .focusedSceneValue(\.commandRouter, router)
            .menuRouter(router)
            .sheet(isPresented: $ui.creatingNote) {
                NewNoteView(notebook: currentNotebook)
            }
            .onAppear {
                model.libraryWindowCount += 1
                if model.canvasWindow == nil { model.canvasWindow = ui.id }
            }
            .onDisappear {
                model.libraryWindowCount -= 1
                if model.canvasWindow == ui.id { model.canvasWindow = nil }
            }
            .onChange(of: model.phase == .unlocked && !model.isBusy) { _, ready in
                if ready { restoreSelection() }
            }
            .onChange(of: model.selectedNoteID) { saveSelection() }
            .onChange(of: model.sidebarSelection) { saveSelection() }
    }

    private var content: some View {
        @Bindable var model = model
        return Group {
            if model.phase == .noVault {
                WelcomeView(openFolder: { pickingVault = true },
                            newVault: { creatingVault = true },
                            openRecent: { entry in Task { await reopen(entry) } },
                            openURL: { url in Task { await open(url) } })
            } else if model.phase == .migrating {
                // A legacy vault: nothing but its migration (format.md §3.3.2).
                MigrationView()
            } else {
                splitView
                .onAppear {
                    // The vault opens on its notebooks: nothing is selected, so a tap pushes.
                    if Platform.isPhone, compactColumn == .sidebar { model.sidebarSelection = nil }
                }
                .onChange(of: model.selectedNoteID) { followSelection() }
                .onChange(of: model.sidebarSelection) { followSelection() }
                .onChange(of: compactColumn) { _, column in
                    guard Platform.isPhone else { return }
                    Task { await model.didShowCompactColumn(column) }
                }
            }
        }
        .fileImporter(isPresented: $pickingVault, allowedContentTypes: UTType.vaultPickerTypes) { result in
            Task {
                await model.report {
                    try await model.open(picked: try result.get(), library: library)
                }
            }
        }
        .onOpenURL { url in Task { await open(url) } }   // a vault tapped in Files
        .onChange(of: scenePhase) { _, phase in
            // iCloud may have delivered files while the app was away; no
            // polling while it is in the background.
            if phase == .active, model.isCloudVault { model.startCloudSync() }
            if phase == .background { model.pauseCloudSync() }
            applyIdleTimer()
        }
        .onChange(of: model.editor != nil) { applyIdleTimer() }
        .onChange(of: keepScreenOn) { applyIdleTimer() }
        .onAppear { applyIdleTimer() }
        .overlay {
            if let progress = model.cloudProgress {
                CloudProgressView(progress: progress) { model.cancelCloudDownload() }
            }
        }
        .sheet(isPresented: $creatingVault) {
            NewVaultView()
        }
        .sheet(isPresented: .constant(model.phase == .locked || keys.holdsUnlockSheet(model))) {
            UnlockView()
                .interactiveDismissDisabled()
        }
        .onChange(of: model.vaultURL) { keys.discardStaleOffer(model) }
        #if DEBUG
        .task {
            if DebugLaunch.isActive {
                storedColumns = DebugLaunch.environment["SEMPERE_DEBUG_COLUMNS"] ?? "detailOnly"
                await DebugLaunch.run(model, library: library)
            }
        }
        #endif
        .alert("Sempere", isPresented: Binding(get: { model.errorMessage != nil },
                                                set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {
                if pickAfterAlert {
                    pickAfterAlert = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        pickingVault = true
                    }
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            // Reopen the last vault on launch; a failure leaves the welcome screen.
            guard !triedAutoOpen, model.phase == .noVault, let last = library.recents.first else { return }
            #if DEBUG
            if DebugLaunch.isActive { return }   // the launch environment names the vault
            #endif
            triedAutoOpen = true
            await reopen(last, pickOnFailure: false)
        }
    }

    /// The three columns. Only an iPhone binds the stack's column
    /// (`preferredCompactColumn`): the iPad (Slide Over, narrow Split View) and
    /// the Mac keep the split view exactly as before.
    @ViewBuilder
    private var splitView: some View {
        if Platform.isPhone {
            NavigationSplitView(columnVisibility: columns, preferredCompactColumn: $compactColumn) {
                SidebarView()
            } content: {
                NoteListView()
            } detail: {
                NoteCanvasView()
            }
        } else {
            NavigationSplitView(columnVisibility: columns) {
                SidebarView()
            } content: {
                NoteListView()
            } detail: {
                NoteCanvasView()
            }
        }
    }

    /// A selection made in code (a search hit, the demo launch) moves the iPhone's stack.
    private func followSelection() {
        guard Platform.isPhone, let next = CompactNavigation.column(
            note: model.selectedNoteID, sidebar: model.sidebarSelection, current: compactColumn) else { return }
        compactColumn = next
    }

    private var currentNotebook: String? {
        if case .notebook(let n)? = model.sidebarSelection { return n }
        return nil
    }

    /// Applies the selection saved with this scene once the vault is unlocked
    /// (Mac only; the iPad keeps starting empty).
    private func restoreSelection() {
        guard Platform.isMac, let vaultID = model.vault?.vaultId, restoredVault != vaultID else { return }
        restoredVault = vaultID
        if let saved = RestorableSelection(stored: storedSelection) { model.restore(saved) }
    }

    private func saveSelection() {
        guard Platform.isMac, model.phase == .unlocked, let vaultID = model.vault?.vaultId, restoredVault == vaultID else { return }
        storedSelection = RestorableSelection(sidebar: model.sidebarSelection, note: model.selectedNoteID, vault: vaultID).stored
    }

    // MARK: - Menu commands (Mac)

    private var router: CommandRouter {
        var context = MenuCommand.Context()
        context.window = .library
        switch model.phase {
        case .noVault: context.vault = .none
        case .locked: context.vault = .locked
        case .migrating: context.vault = .migrating
        case .unlocked: context.vault = .unlocked
        }
        let note = model.selectedNote
        context.hasNote = note != nil && !model.placeholderNoteIDs.contains(note?.id ?? UUID())
        context.noteDeleted = note?.deleted ?? false
        context.hasRecents = !library.recents.isEmpty
        // Only the window whose detail pane hosts the canvas drives the editor.
        let shown = model.editor?.noteID == model.selectedNoteID && model.canvasWindow == ui.id ? model.editor : nil
        context.editingText = ui.searchPresented || ui.renameNoteID != nil || ui.tagsNoteID != nil
            || ui.saveVersionNoteID != nil
        EditorCommands.fill(&context, from: shown)
        return CommandRouter(context: context, recents: library.recents.map { RecentItem(id: $0.id, name: $0.name) },
                             paletteVisible: paletteVisible, exportIDs: model.exportTargetIDs, windowID: ui.id,
                             perform: { command in perform(command, editor: shown) },
                             openRecent: { id in
                                 if let entry = library.recents.first(where: { $0.id == id }) { Task { await reopen(entry) } }
                             })
    }

    private func perform(_ command: MenuCommand, editor: NoteEditor?) {
        if EditorCommands.perform(command, editor: editor, ui: ui) { return }
        let selected = model.selectedNoteID
        switch command {
        case .newNote: ui.creatingNote = true
        case .openNoteInWindow:
            if let selected, let vault = model.vault?.vaultId {
                openWindow(id: NoteWindowValue.sceneID, value: NoteWindowValue(vaultID: vault, noteID: selected))
            }
        case .newVault: creatingVault = true
        case .openVault: pickingVault = true
        case .reopenVault:
            if let last = library.recents.first { Task { await reopen(last) } }
        case .closeVault: model.close()
        case .reloadVault: Task { await model.report { try await model.reload() } }
        case .renameNote: ui.renameNoteID = selected
        case .editTags: ui.tagsNoteID = selected
        case .saveVersion: ui.saveVersionNoteID = selected
        case .deleteNote:
            if let selected { Task { await model.report { try await model.deleteNote(selected) } } }
        case .restoreNote:
            if let selected { Task { await model.report { try await model.restoreNote(selected) } } }
        case .find:
            if ColumnLayout.visibility(from: storedColumns) == .detailOnly { storedColumns = "doubleColumn" }
            ui.searchPresented = true
        case .toggleNoteList: storedColumns = ColumnLayout.toggled(storedColumns)
        default: break
        }
    }

    private func applyIdleTimer() {
        var debug = false
        #if DEBUG
        debug = DebugLaunch.isActive
        #endif
        UIApplication.shared.isIdleTimerDisabled = KeepScreenOn.idleTimerDisabled(
            enabled: keepScreenOn, noteOpen: model.editor != nil, active: scenePhase == .active, debugLaunch: debug)
    }

    private func open(_ url: URL) async {
        await model.report { try await model.open(picked: url, library: library) }
    }

    /// Reopens a recent vault; on failure explains and falls back to the picker.
    private func reopen(_ entry: RecentVault, pickOnFailure: Bool = true) async {
        do {
            try await model.open(recent: entry, library: library)
        } catch is CancellationError {
            // The user stopped the iCloud download.
        } catch {
            model.errorMessage = "Could not reopen “\(entry.name)”: \(error)"
                + (pickOnFailure ? "\n\nChoose the vault folder again." : "")
            pickAfterAlert = pickOnFailure
        }
    }
}
