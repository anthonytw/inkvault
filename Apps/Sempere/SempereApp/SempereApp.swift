import SwiftUI

/// The app entry point. The model, the library (recent vaults) and the
/// remembered keys are app state, shared by every window, so edits from two
/// windows are serialised by one model and never race on the device clock.
///
/// Scenes: the library window (vault, notes, one note on the canvas); on the
/// Mac also a window per note (`NoteWindowView`, restored at launch with the
/// values it was opened with) and one key window. The iPad opens only the
/// first (multiple scenes are switched on for Mac Catalyst alone in the
/// project's build settings), and the Mac menu bar is attached for Catalyst only.
@main
struct SempereApp: App {
    @State private var model = AppModel()
    @State private var library = VaultLibrary()
    @State private var keys = RememberedKeys()

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
        Window("Vault Keys", id: "keys") {
            KeysWindowView()
                .environment(model)
        }
    }

    @SceneBuilder private var libraryScene: some Scene {
        #if targetEnvironment(macCatalyst)
        WindowGroup("Sempere", id: "library") { libraryContent }
            .commands { AppCommands() }
        #else
        WindowGroup { libraryContent }
        #endif
    }

    private var libraryContent: some View {
        RootView()
            .environment(model)
            .environment(library)
            .environment(keys)
    }
}
