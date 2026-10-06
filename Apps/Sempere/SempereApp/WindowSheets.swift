import Sempere
import SwiftUI

/// The rename alert and the tag sheet that menu commands (and the toolbars)
/// open through `WindowUI`, for the window they are attached to.
struct WindowSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let ui: WindowUI
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: ui.renameNoteID) { _, id in
                if let id, let note = model.notes.first(where: { $0.id == id }) { title = note.title }
            }
            .alert("Rename Note", isPresented: Binding(get: { ui.renameNoteID != nil },
                                                       set: { if !$0 { ui.renameNoteID = nil } })) {
                TextField("Title", text: $title)
                Button("Rename") {
                    if let id = ui.renameNoteID {
                        let text = title
                        Task { await model.report { try await model.renameNote(id, to: text) } }
                    }
                    ui.renameNoteID = nil
                }
                Button("Cancel", role: .cancel) { ui.renameNoteID = nil }
            }
            .sheet(isPresented: Binding(get: { ui.tagsNoteID != nil }, set: { if !$0 { ui.tagsNoteID = nil } })) {
                if let id = ui.tagsNoteID { TagEditorView(noteID: id) }
            }
    }
}

extension View {
    func windowSheets(_ ui: WindowUI) -> some View {
        modifier(WindowSheets(ui: ui))
    }
}
