import SwiftUI

/// The app entry point: one window per scene, each with its own model.
/// The library (recent vaults) is shared by every window.
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
