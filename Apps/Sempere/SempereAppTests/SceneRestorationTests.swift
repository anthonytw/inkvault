import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp

/// Windows the system restores where they do not fit: the iPad build
/// ("Designed for iPad" on a Mac) given the scenes the Catalyst build saved in
/// the container they share, or a note window without its value. They show
/// the library or close, and every window has the whole app environment.
@MainActor
@Suite(.serialized)
struct SceneRestorationTests {
    @Test func aSingleSceneBuildShowsTheLibraryWhateverSceneIsRestored() {
        for kind in [SceneRestoration.Kind.library, .note, .settings, .keys] {
            #expect(SceneRestoration.shows(kind, multipleScenes: false) == .library, "\(kind)")
            #expect(SceneRestoration.shows(kind, hasValue: false, multipleScenes: false) == .library, "\(kind)")
        }
    }

    @Test func theMacShowsEachWindowAndClosesANoteWindowWithoutItsNote() {
        #expect(SceneRestoration.shows(.library, multipleScenes: true) == .library)
        #expect(SceneRestoration.shows(.settings, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.keys, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.note, hasValue: true, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.note, hasValue: false, multipleScenes: true) == .closeOpeningLibrary)
    }

    @Test func sceneIDsAreDistinctAndTheMenusUseThem() {
        let ids = [SceneRestoration.Kind.library, .note, .settings, .keys].map(\.sceneID)
        #expect(Set(ids).count == ids.count)
        #expect(SceneRestoration.Kind.library.sceneID == "library")
        #expect(SceneRestoration.Kind.note.sceneID == NoteWindowValue.sceneID)
        #expect(MenuRouting.settingsSceneID == SceneRestoration.Kind.settings.sceneID)
    }

    static func lay<V: View>(_ view: V) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        window.isHidden = true
    }

    /// The root each window gets (`WindowRoot`, which `SempereApp` builds every
    /// `WindowGroup` from), with fakes: a view that reads an environment object
    /// the window lacks traps here (TestFlight: the Settings window restored in
    /// the iPad build on a Mac had no remembered keys).
    @Test func everyWindowRootLaysOutWithTheSharedEnvironment() {
        let model = AppModel()
        let library = VaultLibrary(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("recents.json"))
        let keys = RememberedKeys(store: FakeKeyStore())
        var kinds: [SceneRestoration.Kind] = [.library, .settings, .keys]
        // A note window without its note closes itself and opens the library on
        // the Mac: lay it out only where it shows the library instead.
        if !UIApplication.shared.supportsMultipleScenes { kinds.append(.note) }
        for kind in kinds {
            Self.lay(WindowRoot(kind: kind, model: model, library: library, keys: keys))
        }
        // Each window's own content too, whatever the host's scene support.
        Self.lay(SettingsView(showsDone: false).appEnvironment(model: model, library: library, keys: keys))
        Self.lay(KeysWindowView().appEnvironment(model: model, library: library, keys: keys))
        #expect(model.phase == .noVault)
    }
}
