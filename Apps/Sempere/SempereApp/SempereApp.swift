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
    /// Builds the Mac menu bar without the system's duplicates (`MacMenus`).
    @UIApplicationDelegateAdaptor(SempereAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var library = VaultLibrary()
    @State private var keys = RememberedKeys()

    init() {
        let model = AppModel(recognizer: RecognitionPreference.enabled ? VisionPageRecognizer() : nil,
                             summaryCacheDirectory: AppModel.defaultSummaryCacheDirectory,
                             drawingCacheRoot: AppModel.drawingCacheEnabled ? DrawingCache.defaultRoot : nil,
                             blobCacheRoot: BlobCache.folder,
                             renderCacheRoot: AppModel.drawingCacheEnabled ? RenderCache.defaultRoot : nil,
                             automaticThinning: true,
                             recipientsTrust: AppModel.defaultRecipientsTrust)
        _model = State(initialValue: model)
        // Background sync (iOS): the launch handlers of the scheduled tasks, registered before launch ends.
        BackgroundSync.register(model: model)
        // Staged exports are plaintext copies of notes: none survives a launch.
        ExportJob.purgeStale()
        // Plaintext PDFs dragged out in an earlier run that quit with a vault
        // open (each model empties only its own folder, when the vault closes).
        NotePDFExport.purge(olderThan: 0)
        // Work copies of imported PDFs (plaintext) left by an import that never finished.
        PDFPreparation.purge()
        // Quick voice notes: Siri, Shortcuts, widgets and Control Center act through the shared instance;
        // a voice note a crash interrupted is sealed (or deleted) now.
        QuickCapture.register()
        Task { await QuickCapture.shared.sweep() }
        // Settings shows what the on-device speech engines can do (task E5).
        TranscriptionPreference.installSettingsHooks()
        // Per-session attachment caches of earlier builds (the app's is in Caches now, `BlobCache.folder`).
        BlobCache.purgeStale()
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
