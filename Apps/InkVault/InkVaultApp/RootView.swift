import InkVault
import SwiftUI
import UniformTypeIdentifiers

/// Three columns: sidebar (notebooks, tags), note list, and the note itself.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingVault = false
    #if DEBUG
    @State private var columns: NavigationSplitViewVisibility = DebugLaunch.isActive ? .detailOnly : .all
    #else
    @State private var columns = NavigationSplitViewVisibility.all
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .toolbar {
                    ToolbarItem {
                        Button("Open Vault", systemImage: "folder") { pickingVault = true }
                    }
                }
        } content: {
            NoteListView()
        } detail: {
            NoteCanvasView()
        }
        .fileImporter(isPresented: $pickingVault, allowedContentTypes: [.folder]) { result in
            Task {
                await model.report {
                    try await model.openVault(at: try result.get())
                }
            }
        }
        .sheet(isPresented: .constant(model.phase == .locked)) {
            UnlockView()
                .interactiveDismissDisabled()
        }
        #if DEBUG
        .task {
            if DebugLaunch.isActive { await DebugLaunch.run(model) }
        }
        #endif
        .alert("InkVault", isPresented: Binding(get: { model.errorMessage != nil },
                                                set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
