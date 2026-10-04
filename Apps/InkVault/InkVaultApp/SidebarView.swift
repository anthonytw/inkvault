import SwiftUI

/// Notebooks and tags of the open vault. Selecting one filters the note list.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text").tag(SidebarItem.allNotes)
            if !model.notebooks.isEmpty {
                Section("Notebooks") {
                    ForEach(model.notebooks, id: \.self) { name in
                        Label(name, systemImage: "book.closed").tag(SidebarItem.notebook(name))
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(SidebarItem.tag(tag))
                    }
                }
            }
            Label("Recently Deleted", systemImage: "trash").tag(SidebarItem.deleted)
        }
        .navigationTitle(model.vaultName ?? "InkVault")
        .overlay {
            if model.phase == .noVault {
                ContentUnavailableView("No Vault Open", systemImage: "lock.doc",
                                       description: Text("Open a .inkvault folder to see its notes."))
            }
        }
    }
}
