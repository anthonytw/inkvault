import InkVault
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The welcome screen until a vault is open, then three columns: sidebar
/// (notebooks, tags), note list, and the note itself.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(VaultLibrary.self) private var library
    @State private var pickingVault = false
    @State private var creatingVault = false
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    /// Set when a failed reopen should end in the folder picker.
    @State private var pickAfterAlert = false
    @State private var triedAutoOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = false

    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { ColumnLayout.visibility(from: storedColumns) },
                set: { storedColumns = ColumnLayout.stored($0) })
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .noVault {
                WelcomeView(openFolder: { pickingVault = true },
                            newVault: { creatingVault = true },
                            openRecent: { entry in Task { await reopen(entry) } },
                            openURL: { url in Task { await open(url) } })
            } else if model.phase == .migrating {
                // A legacy vault: nothing but its migration (format.md §3.3.2).
                MigrationView()
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
        .sheet(isPresented: .constant(model.phase == .locked)) {
            UnlockView()
                .interactiveDismissDisabled()
        }
        #if DEBUG
        .task {
            if DebugLaunch.isActive {
                storedColumns = DebugLaunch.environment["INKVAULT_DEBUG_COLUMNS"] ?? "detailOnly"
                await DebugLaunch.run(model, library: library)
            }
        }
        #endif
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
            #if DEBUG
            if DebugLaunch.isActive { return }   // the launch environment names the vault
            #endif
            triedAutoOpen = true
            await reopen(last, pickOnFailure: false)
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
