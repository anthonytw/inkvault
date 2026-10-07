import XCTest

/// Mac Catalyst behaviour that only a running app shows (TestFlight build 6
/// feedback, docs/mac.md): a note opened in a new window gets a window of its
/// own, and the new-note sheet's notebook combo box suggests notebooks.
/// Launches the synthetic demo vault (`DemoLaunch`); skipped on the iPad.
/// Run by `scripts/app.sh test-mac-ui` (CI on `main` and on dispatch).
final class MacWindowUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("Mac Catalyst only")
        #endif
    }

    @MainActor
    private func launch(note: String = "respiration") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               // No windows from an earlier run: the test counts them.
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_NOTE": note,
                                 "SEMPERE_DEMO_MAC_WINDOW": "1100x760", "TZ": "UTC"]
        app.launch()
        return app
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        let labels = app.descendants(matching: .any).allElementsBoundByIndex.prefix(80).map { "\($0.identifier)|\($0.label)" }
        print("MACUIDEBUG \(tag): windows=\(app.windows.count) \(labels)")
    }

    /// File > Open Note in New Window (⌥⌘N) opens a window showing that note,
    /// not a second library window.
    @MainActor
    func testOpenNoteInNewWindowOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["Recently Deleted"].waitForExistence(timeout: 45))
        let libraries = app.descendants(matching: .any).matching(identifier: "libraryWindow").count
        app.typeKey("n", modifierFlags: [.command, .option])
        let noteWindow = app.descendants(matching: .any)["noteWindow"]
        let opened = noteWindow.waitForExistence(timeout: 20)
        if !opened { dump(app, "open-in-window") }
        XCTAssertTrue(opened, "a note window opened")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "libraryWindow").count, libraries,
                       "no second library window")
    }

    /// The new-note sheet's notebook field lists matching notebooks while typing.
    @MainActor
    func testNewNoteSheetSuggestsNotebooks() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["Recently Deleted"].waitForExistence(timeout: 45))
        app.typeKey("n", modifierFlags: .command)
        let field = app.textFields["notebookField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the notebook field")
        field.click()
        field.typeText("Phys")
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Physics")).firstMatch
        let shown = suggestion.waitForExistence(timeout: 10)
        if !shown { dump(app, "new-note") }
        XCTAssertTrue(shown, "School › Physics is suggested")
        // The chevron opens the whole list without typing.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        let toggle = app.buttons["notebookChoices"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the notebook list button")
        toggle.click()
        let any = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Atlas")).firstMatch
        let listed = any.waitForExistence(timeout: 10)
        if !listed { dump(app, "new-note-list") }
        XCTAssertTrue(listed, "the list shows every notebook")
    }
}
