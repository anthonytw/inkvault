import SwiftUI

/// The app entry point. The model and the library (recent vaults) are app
/// state, shared by every window, so edits from two windows are serialised
/// by one model and never race on the device clock.
@main
struct InkVaultApp: App {
    @State private var model = AppModel()
    @State private var library = VaultLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(library)
        }
    }
}
