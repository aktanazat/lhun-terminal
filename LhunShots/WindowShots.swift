import XCTest

/// A session's tmux windows in the palette, on a real device (tools/windows.sh). The fixture is a Mac
/// session `lhun-test-windows-a` with three windows: 0 "editor" and 1 "logs" at shells, 2 "build" running
/// tail; window 1 sits in /private/var/tmp/lhun-test-windows. The walk switches to window 1, renames it,
/// opens a new window, and after each step types `tmux list-windows` into the terminal, so each
/// screenshot shows what tmux on the Mac says. Rows are tapped: the query names no session, so Return
/// would run the palette's create row.
final class WindowShots: XCTestCase {
    private static let session = "lhun-test-windows-a"
    private static let pill = "session.mac.\(session)"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWindowsInThePalette() {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the session's pill is there to read.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-layout", "tabs"]
        app.launch()
        let pill = app.buttons[Self.pill]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(Self.session) never showed in the strip; tools/windows.sh makes it")
        pill.tap()
        XCTAssertTrue(element(app, "terminal").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(Self.session) never attached")
        element(app, "terminal").tap()
        typing(app)
        // Warm-up: the first hardware key after launch can hide and reshow the keyboard.
        app.typeKey("l", modifierFlags: .control)
        sleep(1)
        XCTAssertTrue(pillShows(pill, ":0"), "the pill never showed window 0")

        // The open session's windows, three, the shown one checked. "window of" is among the words that find
        // each one and no other row holds it, where "windows" would also match the window commands; only the
        // rows in sight are drawn. New Window and Rename Window are found by name in the steps below.
        let palette = openPalette(app, typing: "window of")
        for index in 0...2 {
            XCTAssertTrue(element(app, "palette.window.\(index)").waitForExistence(timeout: 10), "window \(index) was never listed")
        }
        XCTAssertEqual(element(app, "palette.window.0").value as? String, "current")
        keep(app, "01-windows")

        // Switch to window 1.
        element(app, "palette.window.1").tap()
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
        XCTAssertTrue(pillShows(pill, ":1"), "the pill never moved to window 1")
        listWindows(app)
        keep(app, "02-switched")

        // Rename window 1.
        _ = openPalette(app, typing: "rename window")
        XCTAssertTrue(element(app, "palette.rename-window").waitForExistence(timeout: 10), "no Rename Window row")
        element(app, "palette.rename-window").tap()
        let dialog = app.alerts["Rename Window"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "no rename dialog")
        let name = dialog.textFields.firstMatch
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "tests")
        keep(app, "03-rename-dialog")
        // Return in the field runs Rename. A tap on the button, while the field holds the keyboard, does not
        // reach the dialog under XCUITest on this iPad.
        name.typeText("\n")
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5), "Return left the rename dialog open")
        listWindows(app)
        keep(app, "04-renamed")

        // A new window, in window 1's folder.
        _ = openPalette(app, typing: "new window")
        XCTAssertTrue(element(app, "palette.new-window").waitForExistence(timeout: 10), "no New Window row")
        element(app, "palette.new-window").tap()
        XCTAssertTrue(pillShows(pill, ":3"), "the pill never moved to the new window")
        listWindows(app, then: "pwd")
        keep(app, "05-new-window")

        // The windows again: four, the new one checked, window 1 renamed.
        _ = openPalette(app, typing: "window of")
        XCTAssertTrue(holds(element(app, "palette.window.3"), "value == %@", "current"), "the new window is not checked")
        XCTAssertTrue(holds(element(app, "palette.window.1"), "label CONTAINS %@", "tests"), "window 1 is not listed as renamed")
        keep(app, "06-windows-after")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5), "⌘K left the palette open")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func openPalette(_ app: XCUIApplication, typing query: String) -> XCUIElement {
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields["palette.query"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K opened no palette")
        palette.typeText(query)
        return palette
    }

    /// Types `tmux list-windows` at the shell of the window on screen, once the terminal has the keyboard.
    @MainActor
    private func listWindows(_ app: XCUIApplication, then extra: String? = nil) {
        typing(app)
        app.typeText("clear; tmux list-windows" + (extra.map { "; " + $0 } ?? "") + "\n")
        sleep(2)
    }

    @MainActor
    private func pillShows(_ pill: XCUIElement, _ text: String) -> Bool {
        holds(pill, "label CONTAINS %@", text)
    }

    @MainActor
    private func holds(_ element: XCUIElement, _ format: String, _ argument: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 15) == .completed
    }

    /// Keys typed while the keyboard slides in are lost.
    @MainActor
    private func typing(_ app: XCUIApplication) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the terminal never got the keyboard back")
        sleep(1)
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
