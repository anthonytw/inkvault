import SwiftUI

/// The app entry point. The model, the library (recent vaults) and the
/// remembered keys are app state, shared by every window, so edits from two
/// windows are serialised by one model and never race on the device clock.
@main
struct SempereApp: App {
    @State private var model = AppModel(summaryCacheDirectory: AppModel.defaultSummaryCacheDirectory,
                                        drawingCacheRoot: AppModel.drawingCacheEnabled ? DrawingCache.defaultRoot : nil)
    @State private var library = VaultLibrary()
    @State private var keys = RememberedKeys()

    init() {
        // Staged exports are plaintext copies of notes: none survives a launch.
        ExportJob.purgeStale()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(library)
                .environment(keys)
        }
        .commands { ExportMenuCommands(model: model) }
    }
}
