import XCTest

/// Text a dark theme can lose, on a real device (tools/visible.sh). The tmux session
/// lhun-test-themes-visible shows tools/visible-pattern.sh in its top pane and omp's input line in its
/// bottom one. The run switches the device to dark (and back afterwards, also when it fails), types
/// `shoot <name> <seconds>` into the top pane, which reprints the pattern and starts tools/snap.sh, hides
/// the keyboard and holds still while the device is photographed.
final class LhunVisibleShots: XCTestCase {
    private let session = "lhun-test-themes-visible"

    @MainActor
    func testFaintTextInDarkMode() throws {
        let appearance = XCUIDevice.shared.appearance
        addTeardownBlock { await MainActor.run { XCUIDevice.shared.appearance = appearance } }
        XCUIDevice.shared.appearance = .dark
        let name = ProcessInfo.processInfo.environment["VISIBLE_SHOT"] ?? "visible"

        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"]
        app.launch()
        let pill = app.descendants(matching: .any)["session.mac.\(session)"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(session) never appeared")
        app.buttons["palette"].tap()
        app.typeText(session)
        let row = app.descendants(matching: .any)["palette.open.mac.\(session)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no row for \(session)")
        row.tap()
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(session) never attached")

        app.typeText("shoot \(name) 8\r")
        let keyboard = OnScreenKeyboard(app)
        if keyboard.up(within: 3) { keyboard.hide.tap() }
        // tools/snap.sh starts its capture 8 s after the command, and a capture takes about 3 s.
        Thread.sleep(forTimeInterval: 14)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
