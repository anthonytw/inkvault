import InkVault
import SwiftUI

/// The selected note: one page at a time on the canvas, with page controls.
/// Opens a `NoteEditor` through the model when the selection changes and
/// saves when the app goes to the background.
struct NoteCanvasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let note = model.selectedNote {
                if let editor = model.editor, editor.noteID == note.id {
                    EditorView(editor: editor)
                        .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
                } else {
                    ProgressView()
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
            }
        }
        .task(id: model.phase == .unlocked ? model.selectedNoteID : nil) {
            await model.report { try await model.openEditor(for: model.selectedNoteID) }
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

    var body: some View {
        VStack(spacing: 0) {
            if let reason = editor.readOnlyReason {
                Banner(text: reason, systemImage: "lock", tint: .secondary)
            }
            if let error = editor.saveError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if let page = editor.currentPage {
                PageCanvasView(editor: editor, pageID: page.id, paper: editor.meta.paper, pageSize: editor.pageSize)
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
