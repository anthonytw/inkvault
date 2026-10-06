import Sempere
import SwiftUI

/// The rename alert and the tag sheet that menu commands (and the toolbars)
/// open through `WindowUI`, for the window they are attached to.
struct WindowSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let ui: WindowUI
    @State private var title = ""
    @State private var versionName = ""

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
            .onChange(of: ui.saveVersionNoteID) { _, id in if id != nil { versionName = "" } }
            .alert("Save Version", isPresented: Binding(get: { ui.saveVersionNoteID != nil },
                                                        set: { if !$0 { ui.saveVersionNoteID = nil } })) {
                TextField("Name (optional)", text: $versionName)
                Button("Save") {
                    if let id = ui.saveVersionNoteID {
                        let name = versionName
                        Task { await model.report { try await model.saveVersion(of: id, name: name) } }
                    }
                    ui.saveVersionNoteID = nil
                }
                Button("Cancel", role: .cancel) { ui.saveVersionNoteID = nil }
            } message: {
                Text("Saved versions are listed first in Version History and are never removed when old autosaves are thinned.")
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
