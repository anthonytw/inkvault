import InkVault
import SwiftUI

/// The selected note: one page at a time on the canvas, with page controls.
/// Opens a `NoteEditor` through the model when the selection changes and
/// saves when the app goes to the background.
struct NoteCanvasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var editingTags = false
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = false

    var body: some View {
        Group {
            if let note = model.selectedNote {
                if let editor = model.editor, editor.noteID == note.id {
                    EditorView(editor: editor)
                        .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
                } else if let failure = model.editorFailure, failure.id == note.id {
                    ContentUnavailableView {
                        Label("Could Not Open Note", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try Again") { Task { await model.showSelectedNote() } }
                    }
                } else if let download = model.noteDownload, download.id == note.id {
                    VStack(spacing: 10) {
                        ProgressView(value: download.progress.fractionCompleted).frame(width: 240)
                        Text("Downloading this note from iCloud: \(download.progress.downloaded) of "
                             + "\(download.progress.total) file\(download.progress.total == 1 ? "" : "s")")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if model.pendingNoteIDs.contains(note.id) {
                    ProgressView("Downloading this note from iCloud…")
                } else {
                    ProgressView("Opening…")
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
            }
        }
        .toolbarTitleMenu {
            if let note = model.selectedNote {
                Button("Rename…", systemImage: "pencil") { newTitle = note.title; renaming = true }
                Button("Tags…", systemImage: "tag") { editingTags = true }
            }
        }
        .alert("Rename Note", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let id = model.selectedNoteID {
                    let title = newTitle
                    Task { await model.report { try await model.renameNote(id, to: title) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingTags) {
            if let id = model.selectedNoteID { TagEditorView(noteID: id) }
        }
        .toolbar {
            if let note = model.selectedNote {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Rename…", systemImage: "pencil") { newTitle = note.title; renaming = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Toggle("Keep Screen On", systemImage: "sun.max", isOn: $keepScreenOn)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Tags", systemImage: note.tags.isEmpty ? "tag" : "tag.fill") { editingTags = true }
                }
            }
            do {
                ToolbarItem(placement: .topBarLeading) {
                    let full = ColumnLayout.visibility(from: storedColumns) == .detailOnly
                    Button(full ? "Show Notes" : "Hide Notes",
                           systemImage: full ? "list.bullet" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation { storedColumns = ColumnLayout.toggled(storedColumns) }
                    }
                    .disabled(!full && model.selectedNote == nil)
                    .help(full ? "Show the note list" : "Hide the note list for a full-width canvas")
                }
            }
        }
        .task(id: model.phase == .unlocked ? model.selectedNoteID : nil) {
            await model.showSelectedNote()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let editor = model.editor {
                Task { await editor.flush() }
            }
        }
    }
}

private struct EditorView: View {
    let editor: NoteEditor
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false

    var body: some View {
        VStack(spacing: 0) {
            if let reason = editor.readOnlyReason {
                Banner(text: reason, systemImage: "lock", tint: .secondary)
            }
            if let error = editor.saveError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if let page = editor.currentPage {
                PageCanvasView(editor: editor, pageID: page.id, paper: editor.meta.paper, pageSize: editor.pageSize,
                               paletteVisible: paletteVisible, paletteCompact: paletteCompact)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc")
                } description: {
                    Text("This note has no pages yet.")
                } actions: {
                    if !editor.isReadOnly {
                        Button("Add Page") { editor.addPage() }
                    }
                }
            }
        }
        .toolbar {
            if !editor.isReadOnly {
                ToolbarItem(placement: .primaryAction) {
                    // Tap: show or hide the palette. Press and hold: compact palette.
                    Menu {
                        Toggle("Compact Palette", systemImage: "rectangle.compress.vertical", isOn: $paletteCompact)
                    } label: {
                        Label(paletteVisible ? "Hide Tools" : "Show Tools",
                              systemImage: paletteVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    } primaryAction: {
                        paletteVisible.toggle()
                    }
                }
            }
            if editor.pages.count > 1 || !editor.isReadOnly {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                        .disabled(editor.pageIndex == 0)
                    Text(editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
                        .monospacedDigit()
                    Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                        .disabled(editor.pageIndex + 1 >= editor.pages.count)
                    if !editor.isReadOnly {
                        Button("Add Page", systemImage: "doc.badge.plus") { editor.addPage() }
                    }
                }
            }
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: SwiftUI.Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}
