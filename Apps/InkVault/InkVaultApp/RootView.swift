import InkVault
import SwiftUI
import UniformTypeIdentifiers

/// The welcome screen until a vault is open, then three columns: sidebar
/// (notebooks, tags), note list, and the note itself.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(VaultLibrary.self) private var library
    @State private var pickingVault = false
    @State private var creatingVault = false
    @State private var columns = NavigationSplitViewVisibility.all
    /// Set when a failed reopen should end in the folder picker.
    @State private var pickAfterAlert = false
    @State private var triedAutoOpen = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .noVault {
                WelcomeView(openFolder: { pickingVault = true },
                            newVault: { creatingVault = true },
                            openRecent: { entry in Task { await reopen(entry) } },
                            openURL: { url in Task { await open(url) } })
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                } content: {
                    NoteListView()
                } detail: {
                    CanvasPlaceholderView(note: model.selectedNote)
                }
            }
        }
        .fileImporter(isPresented: $pickingVault, allowedContentTypes: [.folder]) { result in
            Task {
                await model.report {
                    try await model.open(picked: try result.get(), library: library)
                }
            }
        }
        .sheet(isPresented: $creatingVault) {
            NewVaultView()
        }
        .sheet(isPresented: .constant(model.phase == .locked)) {
            UnlockView()
                .interactiveDismissDisabled()
        }
        .alert("InkVault", isPresented: Binding(get: { model.errorMessage != nil },
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
            triedAutoOpen = true
            await reopen(last, pickOnFailure: false)
        }
    }

    private func open(_ url: URL) async {
        await model.report { try await model.open(picked: url, library: library) }
    }

    /// Reopens a recent vault; on failure explains and falls back to the picker.
    private func reopen(_ entry: RecentVault, pickOnFailure: Bool = true) async {
        do {
            try await model.open(recent: entry, library: library)
        } catch {
            model.errorMessage = "Could not reopen “\(entry.name)”: \(error)"
                + (pickOnFailure ? "\n\nChoose the vault folder again." : "")
            pickAfterAlert = pickOnFailure
        }
    }
}
