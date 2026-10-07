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
        // One snapshot of the tree (querying elements one by one takes seconds each).
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("MACUIDEBUG \(tag) window \(i):\n\(window.debugDescription.prefix(8000))")
        }
    }

    /// File > Open Note in New Window (⌥⌘N) opens a window showing that note,
    /// not a second library window.
    @MainActor
    func testOpenNoteInNewWindowOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["Recently Deleted"].waitForExistence(timeout: 45))
        app.typeKey("n", modifierFlags: [.command, .option])
        assertOneNoteWindow(app, "shortcut")
    }

    /// The same from the note list's context menu.
    @MainActor
    func testTheContextMenuOpensANoteWindow() throws {
        let app = launch()
        defer { app.terminate() }
        let row = app.staticTexts["Cellular Respiration"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45))
        row.rightClick()
        let item = app.menuItems["Open in New Window"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the context menu offers a new window")
        item.click()
        assertOneNoteWindow(app, "context menu")
    }

    /// The File menu has no system New Window or Open… beside the app's commands.
    @MainActor
    func testTheFileMenuHasNoSystemDuplicates() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["Recently Deleted"].waitForExistence(timeout: 45))
        let file = app.menuBars.menuBarItems["File"]
        file.click()
        let titles = file.menuItems.allElementsBoundByIndex.map(\.title)
        let identifiers = file.menuItems.allElementsBoundByIndex.map(\.identifier)
        print("MACUIDEBUG file menu: \(titles) \(identifiers)")
        for menu in ["Edit", "View", "Note", "Tools"] {
            let items = app.menuBars.menuBarItems[menu].menuItems.allElementsBoundByIndex.map(\.title)
            print("MACUIDEBUG \(menu) menu: \(items)")
        }
        XCTAssertTrue(titles.contains("New Note…"))
        XCTAssertTrue(titles.contains("Open Vault…"))
        XCTAssertFalse(identifiers.contains("new_window"), "no system New Window")
        XCTAssertFalse(identifiers.contains("open:"), "no system Open…")
        XCTAssertEqual(titles.filter { $0 == "Open Recent" }.count, 1, "one Open Recent")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    @MainActor
    private func assertOneNoteWindow(_ app: XCUIApplication, _ how: String) {
        let opened = app.descendants(matching: .any)["noteWindow"].waitForExistence(timeout: 20)
        if !opened { dump(app, how) }
        XCTAssertTrue(opened, "\(how): a note window opened")
        let libraries = app.descendants(matching: .any).matching(identifier: "libraryWindow").count
        XCTAssertEqual(libraries, 1, "\(how): one library window (windows: \(app.windows.count))")
    }

    /// The new-note sheet's notebook field lists matching notebooks while typing.
    @MainActor
    func testNewNoteSheetSuggestsNotebooks() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["Recently Deleted"].waitForExistence(timeout: 45))
        // The note list's toolbar button, as on the iPad (⌘N is checked by the File menu test).
        let newNote = app.buttons["New Note"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 20), "the New Note button")
        newNote.click()
        let field = app.textFields["notebookField"]
        let found = field.waitForExistence(timeout: 20)
        if !found { dump(app, "new-note-sheet") }
        XCTAssertTrue(found, "the notebook field")
        guard found else { return }
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
