import XCTest

/// Programs that report their status over OSC 7501 drive the pills and the palette, on the Mac and the
/// server. Its sessions come first from /private/var/tmp/lhun-status/acc/setup.sh. The test types
/// `sh run <session> <report>` into the driver session, and that session's own shell prints the report.
final class LhunStatusShots: XCTestCase {
    @MainActor
    func testProgramsReportTheirStatus() throws {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the sessions' pills are there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        let drive = pill(app, "drive")
        let subject = pill(app, "a")
        let silent = pill(app, "f")
        XCTAssertTrue(drive.waitForExistence(timeout: 30), "the driver session never appeared")
        open(app, drive)
        try attached(app)

        report(app, "a working")
        try waitFor(subject, "working")
        keep("1-working")

        report(app, "a question")
        try waitFor(subject, "needs you, question: Which branch?")
        app.buttons["palette"].tap()
        // Only the rows in sight are drawn, and the Mac's other sessions can list above it, so its name
        // narrows the list first.
        app.typeText("lhun-test-status-a")
        let row = app.descendants(matching: .any)["palette.open.mac.lhun-test-status-a"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette never listed the session")
        try waitFor(row, "needs you, question: Which branch?")
        keep("2-palette-question")
        app.typeKey(".", modifierFlags: .command)

        report(app, "a done")
        try waitFor(subject, "finished")
        open(app, subject)
        try attached(app)
        try waitFor(subject, "")
        open(app, drive)
        try attached(app)
        try holds(subject, "", seconds: 3)
        report(app, "a done")
        try waitFor(subject, "finished")
        keep("3-finished-again")

        report(app, "a error")
        try waitFor(subject, "needs you, failed: Build failed")
        keep("4-failed")

        report(app, "a wrapped")
        try waitFor(subject, "working")

        report(app, "a child")
        try waitFor(subject, "needs you, approval: Run tests?")
        report(app, "a unchild")
        try waitFor(subject, "working")

        report(app, "a bad")
        try holds(subject, "working", seconds: 3)

        report(app, "a clear")
        try waitFor(subject, "")
        report(app, "a job")
        try waitFor(subject, "working")
        try waitFor(subject, "", timeout: 20)

        report(app, "f bell")
        try waitFor(silent, "working")
        try waitFor(silent, "needs you", timeout: 25)
        keep("5-fallback-bell")

        report(app, "h deploy")
        app.buttons["palette"].tap()
        app.typeText("lhun-test-status-h")
        let server = app.descendants(matching: .any)["palette.open.server.lhun-test-status-h"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10), "the palette never listed the server's session")
        try waitFor(server, "needs you, approval: Deploy?", timeout: 20)
        keep("6-server-needs-you")
        app.typeKey(".", modifierFlags: .command)
    }

    @MainActor
    private func pill(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["session.mac.lhun-test-status-\(name)"].firstMatch
    }

    /// Taps a session's pill, first dragging the strip until the pill is on screen: the Mac's other
    /// sessions, other agents' among them, can push it out of view.
    @MainActor
    private func open(_ app: XCUIApplication, _ pill: XCUIElement) {
        for _ in 0..<10 where !pill.isHittable {
            let strip = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: pill.frame.midY))
            let shift: CGFloat = pill.frame.midX < app.frame.midX ? 240 : -240
            strip.press(forDuration: 0.05, thenDragTo: strip.withOffset(CGVector(dx: shift, dy: 0)))
        }
        pill.tap()
    }

    /// Waits until the session just opened attaches, and gives its terminal the keyboard.
    @MainActor
    private func attached(_ app: XCUIApplication) throws {
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
        terminal.tap()
    }

    /// Types `sh run <words>` into the driver session, which makes the named session report.
    @MainActor
    private func report(_ app: XCUIApplication, _ words: String) {
        app.textViews["terminal"].firstMatch.tap()
        app.typeText("sh run \(words)\r")
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 15) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while (element.value as? String ?? "") != value {
            guard Date.now < deadline else {
                throw Timeout(errorDescription: "\(element.identifier) read \"\(element.value as? String ?? "")\", never \"\(value)\"")
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
    }

    /// Fails if the element's value moves off `value` within `seconds`.
    @MainActor
    private func holds(_ element: XCUIElement, _ value: String, seconds: TimeInterval) throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            let now = element.value as? String ?? ""
            guard now == value else {
                throw Timeout(errorDescription: "\(element.identifier) moved from \"\(value)\" to \"\(now)\"")
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
    }

    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private struct Timeout: LocalizedError {
        let errorDescription: String?
    }
}
