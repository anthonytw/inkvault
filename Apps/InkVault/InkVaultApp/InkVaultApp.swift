import SwiftUI

/// The app entry point: one window per scene, each with its own model.
@main
struct InkVaultApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
