import XCTest

/// Real drags onto the sidebar (TestFlight builds 6 and 7: dropping a note on a
/// notebook, or a notebook on another, did nothing on the iPad and the Mac).
/// The drop delegate needs a real drag session, which only a running app
/// has: these drag rows of the synthetic demo vault (`DemoLaunch`) with the
/// pointer and check where the notes ended up. `SEMPERE_DEBUG_DROPS` makes
/// the app record which drag and drop callbacks ran (`DropTrace`), printed
/// as `DROPDEBUG` lines so a failure says where the drop stopped.
///
/// Run by `scripts/app.sh test-ui` (iPad simulator, every CI run of the app
/// job) and `scripts/app.sh test-mac-ui` (Mac Catalyst, main and dispatch).
final class SidebarDropUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        var env = ["SEMPERE_DEMO": "1", "SEMPERE_DEBUG_COLUMNS": "all", "SEMPERE_DEMO_SIDEBAR": "all",
                   "SEMPERE_DEBUG_DROPS": "1", "TZ": "UTC"]
        #if targetEnvironment(macCatalyst)
        env["SEMPERE_DEMO_MAC_WINDOW"] = "1100x760"
        #endif
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func trace(_ app: XCUIApplication, _ tag: String) {
        let label = app.staticTexts["drop-trace"].firstMatch
        print("DROPDEBUG \(tag): \(label.exists ? label.label : "(no trace label)")")
    }

    /// A sidebar notebook row by its path (`sidebar-notebook-<path>`).
    @MainActor
    private func sidebarRow(_ app: XCUIApplication, _ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar-notebook-\(path)").firstMatch
    }

    /// Waits for `element`; on a miss prints the window tree (`DROPDEBUG`) so the log says what was there.
    @MainActor
    private func require(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        for (i, window) in app.windows.allElementsBoundByIndex.enumerated() {
            print("DROPDEBUG tree \(what) window \(i):\n\(window.debugDescription.prefix(12000))")
        }
        XCTFail("\(what) not found", file: file, line: line)
    }

    /// A row of the note list by its note's title.
    @MainActor
    private func noteRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func drag(_ source: XCUIElement, onto target: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        source.click(forDuration: 0.6, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.0)
        #else
        source.press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.0)
        #endif
    }

    @MainActor
    private func select(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// Selects notebook `title` in the sidebar and waits until the list shows
    /// `expected` (a note known to be in it) and no longer shows `outside`.
    @MainActor
    private func show(_ app: XCUIApplication, notebook title: String, expected: String, outside: String) {
        let row = sidebarRow(app, title)
        require(row, "sidebar row \(title)", in: app)
        select(row)
        XCTAssertTrue(noteRow(app, expected).waitForExistence(timeout: 20), "\(title) lists \(expected)")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: noteRow(app, outside))
        wait(for: [gone], timeout: 20)
    }

    /// A note dragged from the list onto a notebook in the sidebar moves into it.
    @MainActor
    func testDroppingANoteOnANotebookMovesIt() throws {
        let app = launch()
        defer { app.terminate() }
        let note = noteRow(app, "Grocery list")
        require(note, "note row", in: app, timeout: 90)
        let personal = sidebarRow(app, "Personal")
        require(personal, "sidebar row Personal", in: app)
        sleep(2)   // let the list settle
        drag(note, onto: personal)
        sleep(3)   // the move is one commit, then the list re-reads the note
        trace(app, "note onto notebook")
        show(app, notebook: "Personal", expected: "Lisbon itinerary", outside: "Quick thoughts")
        XCTAssertTrue(noteRow(app, "Grocery list").waitForExistence(timeout: 20), "the dropped note is in Personal")
    }

    /// A notebook dragged onto another notebook nests there (with its notes).
    @MainActor
    func testDroppingANotebookOnANotebookNestsIt() throws {
        let app = launch()
        defer { app.terminate() }
        require(noteRow(app, "Grocery list"), "note row", in: app, timeout: 90)
        let work = sidebarRow(app, "Work"), personal = sidebarRow(app, "Personal")
        require(work, "sidebar row Work", in: app)
        require(personal, "sidebar row Personal", in: app)
        sleep(2)
        drag(work, onto: personal)
        sleep(3)
        trace(app, "notebook onto notebook")
        show(app, notebook: "Personal", expected: "Lisbon itinerary", outside: "Quick thoughts")
        XCTAssertTrue(noteRow(app, "Sprint planning").waitForExistence(timeout: 20), "Work/Atlas is now inside Personal")
    }
}
