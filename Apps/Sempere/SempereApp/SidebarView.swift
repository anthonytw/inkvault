import Sempere
import SwiftUI

/// Notebooks (a tree of `/`-separated paths) and tags of the open vault.
/// Selecting a notebook shows the notes in it and in its sub-notebooks.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(RememberedKeys.self) private var keys
    @State private var forgettingKey = false
    @State private var showingSettings = false
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text").tag(SidebarItem.allNotes)
            let tree = model.notebookTree
            if !tree.isEmpty {
                Section("Notebooks") {
                    OutlineGroup(tree, children: \.childrenOrNil) { node in
                        Label(node.name, systemImage: node.children.isEmpty ? "book.closed" : "books.vertical")
                            .tag(SidebarItem.notebook(node.path))
                            .contextMenu {
                                Button("Rename or Move…", systemImage: "pencil") { newName = node.path; renaming = node.path }
                            }
                            .swipeActions {
                                Button("Rename", systemImage: "pencil") { newName = node.path; renaming = node.path }
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
        .navigationTitle(model.vaultName ?? "Sempere")
        .toolbar {
            ToolbarItem {
                Button("Close Vault", systemImage: "xmark.circle") { model.close() }
            }
            ToolbarItem {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
            ToolbarItem {
                Menu("Vault Key", systemImage: "key") {
                    if let storage = keys.storage(for: model) {
                        Text(storage == .iCloudKeychain ? "Saved in iCloud Keychain" : "Saved on \(RememberedKeys.deviceName)")
                        Button("Forget Key for This Vault…", systemImage: "key.slash", role: .destructive) {
                            forgettingKey = true
                        }
                    } else {
                        Text("The key is not saved. Unlock with a passphrase or pasted key to save it.")
                    }
                }
            }
        }
        .task(id: model.vault?.vaultId) { await keys.refresh(model) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog("Forget this vault's key?", isPresented: $forgettingKey, titleVisibility: .visible) {
            Button("Forget Key", role: .destructive) {
                Task { await model.report { try await keys.forget(model) } }
            }
        } message: {
            Text(keys.storage(for: model) == .iCloudKeychain
                 ? "The key is removed from iCloud Keychain on all your devices. Keep another copy (key file or passphrase) to open the vault again."
                 : "The key is removed from \(RememberedKeys.deviceName). Keep another copy (key file or passphrase) to open the vault again.")
        }
        .alert("Rename or Move Notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Path", text: $newName)
                .autocorrectionDisabled()
            Button("Rename") {
                if let old = renaming {
                    Task { await model.report { try await model.renameNotebook(old, to: newName) } }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Applies to every note in “\(renaming ?? "")” and its sub-notebooks. Use / for levels, e.g. School/Math. An empty name takes the notes out of the notebook and lifts its sub-notebooks to the top.")
        }
    }
}
