import XCTest

/// Walks the session marks and live program names on a real device, against two tmux sessions on the
/// Mac named lhun-test-watch-a and lhun-test-watch-b and one on the server named lhun-test-watch-h
/// whose second window has rung its bell, and keeps a screenshot of each step: a job spinning in a
/// session he is not looking at, its bell asking for him, the palette listing both hosts' sessions that
/// want him, the mark clearing once he opens the session from there, the session's program going from zsh
/// to node and back, and the palette's sound switch.
final class LhunWatchShots: XCTestCase {
    @MainActor
    func testMarksAndLiveProgramNames() throws {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, and the Mac's, whichever host the last run
        // left open, so the sessions' pills are there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        let job = pill(app, "lhun-test-watch-a")
        let other = pill(app, "lhun-test-watch-b")
        XCTAssertTrue(job.waitForExistence(timeout: 30), "lhun-test-watch-a never appeared")

        job.tap()
        try attached(app)
        app.typeText("sleep 20; printf '\\a'\n")
        other.tap()
        try attached(app)
        try waitFor(job, "working", timeout: 10)
        keep("1-working")

        try waitFor(job, "needs you", timeout: 40)
        keep("2-needs-you")

        app.buttons["palette"].tap()
        // Only the rows in sight are drawn, and the hosts' other sessions may want him too, so the fixtures'
        // shared name narrows the list to them first.
        app.typeText("lhun-test-watch")
        let row = app.descendants(matching: .any)["palette.open.mac.lhun-test-watch-a"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette never listed the job")
        let server = app.descendants(matching: .any)["palette.open.server.lhun-test-watch-h"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5), "the palette never listed the server's session")
        keep("3-palette-needs-you")

        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["palette.query"].firstMatch.waitForNonExistence(timeout: 5))
        try attached(app)
        try waitFor(job, "", timeout: 5)
        try waitFor(job, showing: "zsh", timeout: 5)
        keep("4-opened-zsh")

        app.typeText("node -e 'setTimeout(() => {}, 8000)'\n")
        try waitFor(job, showing: "node", timeout: 5)
        keep("5-node")
        try waitFor(job, showing: "zsh", timeout: 15)
        keep("6-zsh-again")

        app.buttons["palette"].tap()
        app.typeText("sound")
        XCTAssertTrue(app.descendants(matching: .any)["palette.sounds"].firstMatch.waitForExistence(timeout: 5))
        keep("7-palette-sounds")
    }

    @MainActor
    private func pill(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
    }

    /// Waits until the session just opened attaches, and gives its terminal the keyboard.
    @MainActor
    private func attached(_ app: XCUIApplication) throws {
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
        terminal.tap()
    }

    /// Waits for a pill's mark, as VoiceOver reads it: "working", "finished", "needs you", or none.
    @MainActor
    private func waitFor(_ pill: XCUIElement, _ mark: String, timeout: TimeInterval) throws {
        try waitUntil(timeout, "the pill's mark never became \"\(mark)\"") { (pill.value as? String ?? "") == mark }
    }

    /// Waits for a pill to name a program.
    @MainActor
    private func waitFor(_ pill: XCUIElement, showing program: String, timeout: TimeInterval) throws {
        try waitUntil(timeout, "the pill never showed \(program)") { pill.label.contains(program) }
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ failure: String, _ done: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !done() {
            guard Date.now < deadline else { throw Timeout(errorDescription: failure) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private struct Timeout: LocalizedError {
        let errorDescription: String?
    }

    /// The whole screen: with the iPad lying in landscape, the app's own screenshot keeps only a
    /// portrait-sized corner of it.
    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
