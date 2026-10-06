import XCTest

/// Captures the App Store screenshots from the synthetic demo vault
/// (`DemoVault`, opened through `SEMPERE_DEMO*` launch variables, `DemoLaunch`).
/// Run through `scripts/screenshots.sh`, which sets the simulator up (status bar,
/// light mode) and passes `TEST_RUNNER_SEMPERE_SHOTS_DIR`: the PNGs are written
/// there and also attached to the result bundle.
///
/// Each shot is a fresh launch whose state comes from the environment, so the
/// test taps nothing: a change to the UI cannot break a shot's navigation.
final class ScreenshotTests: XCTestCase {
    /// One screenshot: its file name, the launch variables, and the label to wait for.
    struct Shot {
        let name: String
        let environment: [String: String]
        let waitFor: String
    }

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// The shots for this platform, in the order they appear on the store page.
    static var shots: [Shot] {
        let respiration = "Note title: Cellular Respiration"
        let atlas = "Note title: Sync design sketch"
        let all = isMac ? "all" : "detailOnly"
        func env(_ columns: String, _ extra: [String: String]) -> [String: String] {
            var e = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": columns]
            if isMac { e["SEMPERE_DEMO_MAC_WINDOW"] = "1280x800" }
            for (k, v) in extra { e[k] = v }
            return e
        }
        return [
            Shot(name: "01-write", environment: env(all, ["SEMPERE_DEMO_NOTE": "respiration"]), waitFor: respiration),
            Shot(name: "02-sketch", environment: env(all, ["SEMPERE_DEMO_NOTE": "atlas"]), waitFor: atlas),
            Shot(name: "03-notes", environment: env("doubleColumn", ["SEMPERE_DEMO_NOTE": "respiration"]), waitFor: respiration),
            // Narrow layouts hide the note's own title, so wait for the note's row in the list.
            Shot(name: "04-tags", environment: env("all", ["SEMPERE_DEMO_NOTE": "respiration", "SEMPERE_DEMO_SIDEBAR": "tag:lecture"]),
                 waitFor: "Cellular Respiration"),
            Shot(name: "05-paper", environment: env(all, ["SEMPERE_DEMO_NOTE": "atlas", "SEMPERE_DEMO_PAPER_PICKER": "1"]),
                 waitFor: "Apply to This Page"),
            Shot(name: "06-unlock", environment: env("all", ["SEMPERE_DEMO_LOCKED": "1"]), waitFor: "Unlock My Notes"),
        ]
    }

    @MainActor
    func testCaptureScreenshots() throws {
        continueAfterFailure = true
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let directory = ProcessInfo.processInfo.environment["SEMPERE_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for shot in Self.shots {
            capture(shot, to: directory)
        }
    }

    @MainActor
    private func capture(_ shot: Shot, to directory: URL?) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = shot.environment
        app.launch()
        let label = NSPredicate(format: "label CONTAINS %@", shot.waitFor)
        let found = app.descendants(matching: .any).matching(label).firstMatch.waitForExistence(timeout: 45)
        XCTAssertTrue(found, "\(shot.name): never showed “\(shot.waitFor)”")
        if !found {
            // What was on screen, for the CI log.
            let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(60).map(\.label).filter { !$0.isEmpty }
            print("SHOTDEBUG \(shot.name): \(labels)")
        }
        // PencilKit draws its tiles asynchronously; the sheets and the palette settle too.
        Thread.sleep(forTimeInterval: 6)
        let screenshot = Self.isMac ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = shot.name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory {
            do {
                try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(shot.name).png"))
            } catch {
                // The Mac runner is sandboxed; its shots are read from the result bundle's attachments.
                if !Self.isMac { XCTFail("\(shot.name): could not write the PNG: \(error)") }
            }
        }
        app.terminate()
    }
}
