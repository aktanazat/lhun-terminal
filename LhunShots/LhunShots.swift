import XCTest

/// Drives Lhûn on a real device against a real tmux session named `proof` on the Mac (tools/shots.sh
/// creates it), and keeps a screenshot of each step. The device's own orientation is used as it is.
final class LhunShots: XCTestCase {
    @MainActor
    func testAttachTypeAndScroll() throws {
        let app = XCUIApplication()
        // Launch arguments override saved settings for this run only: no key sheet, no session restored.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", ""]
        app.launch()

        let row = app.descendants(matching: .any)["session.mac.proof"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the proof session never appeared")
        keep(app, "1-sessions")

        row.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")

        terminal.tap()
        app.typeText("echo lhun-$((6*7))-ok\n")
        sleep(2)
        keep(app, "2-attached")

        // A downward swipe opens tmux's history; swiping back up to the bottom leaves it.
        terminal.swipeDown()
        sleep(2)
        keep(app, "3-history")
        terminal.swipeUp()
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
