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
    @State private var model = AppModel(recognizer: RecognitionPreference.enabled ? VisionPageRecognizer() : nil,
                                        summaryCacheDirectory: AppModel.defaultSummaryCacheDirectory,
                                        drawingCacheRoot: AppModel.drawingCacheEnabled ? DrawingCache.defaultRoot : nil,
                                        blobCacheRoot: BlobCache.folder,
                                        renderCacheRoot: AppModel.drawingCacheEnabled ? RenderCache.defaultRoot : nil,
                                        attachmentIndexRoot: AppModel.defaultAttachmentIndexRoot,
                                        automaticThinning: true,
                                        recipientsTrust: AppModel.defaultRecipientsTrust)
    @State private var library = VaultLibrary()
    @State private var keys = RememberedKeys()

    init() {
        // Staged exports are plaintext copies of notes: none survives a launch.
        ExportJob.purgeStale()
        BulkExportRun.purgeStale()
        // A key file staged for the share sheet by a run that quit with the sheet up.
        KeyShareFile.purge()
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
        WindowGroup("Settings", id: MenuRouting.settingsSceneID) {
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
            // File > Export… is a `MenuCommand` on the Mac (`AppCommands`); the iPad keeps the submenu.
            .commands { AppCommands() }
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
