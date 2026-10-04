import SwiftUI

/// Notebooks and tags of the open vault. Selecting one filters the note list.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text").tag(SidebarItem.allNotes)
            if !model.notebooks.isEmpty {
                Section("Notebooks") {
                    ForEach(model.notebooks, id: \.self) { name in
                        Label(name, systemImage: "book.closed").tag(SidebarItem.notebook(name))
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") { newName = name; renaming = name }
                            }
                            .swipeActions {
                                Button("Rename", systemImage: "pencil") { newName = name; renaming = name }
                            }
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
        .toolbar {
            ToolbarItem {
                Button("Close Vault", systemImage: "xmark.circle") { model.close() }
            }
        }
        .alert("Rename Notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming {
                    Task { await model.report { try await model.renameNotebook(old, to: newName) } }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Applies to every note in “\(renaming ?? "")”. An empty name removes them from the notebook.")
        }
    }
}
