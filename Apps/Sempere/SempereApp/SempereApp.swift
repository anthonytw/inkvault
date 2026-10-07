import SwiftUI

/// The app entry point. The model, the library (recent vaults) and the
/// remembered keys are app state, shared by every window, so edits from two
/// windows are serialised by one model and never race on the device clock.
///
/// Scenes: the library window (vault, notes, one note on the canvas); on the
/// Mac also a window per note (`NoteWindowView`, restored at launch with the
/// values it was opened with), one key window and one Settings window (⌘,). The iPad opens only the
/// first (multiple scenes are switched on for Mac Catalyst alone in the
/// project's build settings), and the Mac menu bar is attached for Catalyst only.
@main
struct SempereApp: App {
    @State private var model = AppModel(recognizer: RecognitionPreference.enabled ? VisionPageRecognizer() : nil,
                                        summaryCacheDirectory: AppModel.defaultSummaryCacheDirectory,
                                        drawingCacheRoot: AppModel.drawingCacheEnabled ? DrawingCache.defaultRoot : nil,
                                        automaticThinning: true)
    @State private var library = VaultLibrary()
    @State private var keys = RememberedKeys()

    init() {
        // Staged exports are plaintext copies of notes: none survives a launch.
        ExportJob.purgeStale()
        // Plaintext PDFs dragged out in an earlier run that quit with a vault
        // open (each model empties only its own folder, when the vault closes).
        NotePDFExport.purge(olderThan: 0)
        // Work copies of imported PDFs (plaintext) left by an import that never finished.
        PDFPreparation.purge()
    }

    var body: some Scene {
        libraryScene
        WindowGroup("Note", id: NoteWindowValue.sceneID, for: NoteWindowValue.self) { $value in
            if let value {
                NoteWindowView(value: value)
                    .environment(model)
                    .environment(library)
                    .environment(keys)
            }
        }
        WindowGroup("Settings", id: "settings") {
            SettingsView(showsDone: false)
                .environment(model)
        }
        WindowGroup("Vault Keys", id: "keys") {
            KeysWindowView()
                .environment(model)
        }
    }

    @SceneBuilder private var libraryScene: some Scene {
        #if targetEnvironment(macCatalyst)
        WindowGroup("Sempere", id: "library") { libraryContent }
            .commands {
                AppCommands()
                ExportMenuCommands(model: model)
            }
        #else
        WindowGroup { libraryContent }
            .commands { ExportMenuCommands(model: model) }
        #endif
    }

    private var libraryContent: some View {
        RootView()
            .environment(model)
            .environment(library)
            .environment(keys)
    }
}
