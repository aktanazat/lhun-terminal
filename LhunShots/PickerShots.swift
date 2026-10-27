import XCTest

/// The path picker, saved actions, the palette's create row and the screen copy on a real device
/// (tools/picker.sh). Fixtures: a Mac session `lhun-test-palette-picker` in the selected checkout, a folder
/// /private/var/tmp/lhun-test-palette-folder, and a server action titled "lhun-test-palette server logs"
/// that starts a session. Every session the run starts is named lhun-test-palette-*, and each step keeps a
/// screenshot. Without a hardware keyboard the on-screen one would type Escape as text, so the palette
/// closes with ⌘K.
final class PickerShots: XCTestCase {
    @MainActor
    func testPathsActionsCreateAndCopy() {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the session's pill is there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-layout", "tabs"]
        app.launch()
        open(app, "lhun-test-palette-picker")
        let paths = app.textFields["paths.query"]
        let palette = app.textFields["palette.query"]

        // Insert Path: ⌘P over a half-typed command, a search, and Return.
        element(app, "terminal").tap()
        app.typeText("clear\n")
        app.typeText("wc -l ")
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(paths.waitForExistence(timeout: 5), "⌘P opened no picker")
        paths.typeText("Hosts.swift")
        XCTAssertTrue(element(app, "paths.Lhun/Hosts.swift").waitForExistence(timeout: 20), "the picker never offered Hosts.swift")
        keep(app, "01-insert-matching")
        paths.typeText("\n")
        XCTAssertTrue(paths.waitForNonExistence(timeout: 5), "picking a file left the picker open")
        typing(app)
        keep(app, "02-insert-at-prompt")
        app.typeText("\n")
        sleep(1)
        keep(app, "03-insert-ran")

        // Copy Screen, pasted into a file that tools/picker.sh prints afterwards.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K opened no palette")
        palette.typeText("copy screen")
        XCTAssertTrue(element(app, "palette.copy-screen").waitForExistence(timeout: 5), "no Copy Screen row")
        palette.typeText("\n")
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
        typing(app)
        app.typeText("clear; cat > /private/var/tmp/lhun-test-palette-paste.txt\n")
        sleep(1)
        app.typeKey("v", modifierFlags: .command)
        sleep(2)
        keep(app, "04-copy-pasted")
        // The paste ends mid-line: one Ctrl-D hands that line to cat, the next ends it.
        app.typeKey("d", modifierFlags: .control)
        app.typeKey("d", modifierFlags: .control)
        app.typeText("clear\n")

        // Share Screen opens the share sheet; tapping outside closes it and gives the keyboard back.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("share screen")
        XCTAssertTrue(element(app, "palette.share-screen").waitForExistence(timeout: 5), "no Share Screen row")
        palette.typeText("\n")
        sleep(4)
        keep(app, "05-share-sheet")
        let outside = app.otherElements["PopoverDismissRegion"]
        (outside.exists ? outside : element(app, "terminal")).tap()
        typing(app)

        // Go to Folder: starts on the session's folder; a path typed in one go walks there and filters.
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(paths.waitForExistence(timeout: 5), "⇧⌘G opened no picker")
        XCTAssertTrue(element(app, "paths.Lhun/").waitForExistence(timeout: 15), "Go to Folder never listed the session's folder")
        keep(app, "06-go-to-folder")
        paths.typeText("/private/var/tmp/lhun-test-palette")
        XCTAssertTrue(app.staticTexts["/private/var/tmp"].waitForExistence(timeout: 15), "typing a path never walked to it")
        XCTAssertTrue(element(app, "paths.lhun-test-palette-folder/").waitForExistence(timeout: 15), "the fixture folder never showed up")
        keep(app, "07-go-to-folder-filtered")
        paths.typeText("\n")
        attached(app, "session.mac.lhun-test-palette-folder")
        keep(app, "08-go-to-folder-opened")

        // A name that matches no session offers a new session by that name; one tmux would refuse is refused.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("lhun-test-palette-new")
        XCTAssertTrue(element(app, "palette.create").waitForExistence(timeout: 5), "no create row for an unused name")
        keep(app, "09-create-row")
        palette.typeText("\n")
        attached(app, "session.mac.lhun-test-palette-new")
        keep(app, "10-create-opened")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("lhun-test-palette.x")
        XCTAssertTrue(element(app, "palette.create").waitForExistence(timeout: 5), "no row for a refused name")
        keep(app, "11-create-refused")
        // ⌘K comes in as a hardware key, so iOS keeps the on-screen keyboard down after it.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5), "⌘K left the palette open")
        sleep(1)

        // Both hosts' saved actions, which "saved action" among the words that find each one lists with
        // "actions"; one starts a session on the server.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("actions")
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "palette.action.", "lhun-test-palette mac echo"
        )).firstMatch.waitForExistence(timeout: 15), "the Mac's fixture action never showed up")
        let serverAction = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "palette.action.", "lhun-test-palette server logs"
        )).firstMatch
        XCTAssertTrue(serverAction.waitForExistence(timeout: 15), "the server's fixture action never showed up")
        keep(app, "12-actions")
        palette.typeText(" palette server")
        XCTAssertTrue(serverAction.waitForExistence(timeout: 5))
        palette.typeText("\n")
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
        // The strip stays on the Mac, so the server session has no pill here; give it time to attach.
        sleep(6)
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the action's session never attached")
        keep(app, "13-action-session")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) {
        let session = element(app, "session.mac.\(name)")
        XCTAssertTrue(session.waitForExistence(timeout: 30), "\(name) never appeared")
        session.tap()
        XCTAssertTrue(element(app, "terminal").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
    }

    /// Waits for a session the app just started to show up and attach.
    @MainActor
    private func attached(_ app: XCUIApplication, _ pill: String) {
        XCTAssertTrue(element(app, pill).waitForExistence(timeout: 20), "\(pill) never appeared")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(pill) never attached")
        sleep(2)
    }

    /// Waits until the terminal has the keyboard back and the keyboard has finished coming up, since keys
    /// typed while it slides in are lost.
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
