import XCTest

/// Program marks in the session strip on a real device, against the Mac sessions tools/clawd.sh makes,
/// all named after the prefix it passes in CLAWD_PREFIX: <prefix>-omp runs omp itself, reporting its model
/// through tools/omp/lhun-model.ts, and <prefix>-claude a stand-in named claude (a copy of cat). In
/// <prefix>-ctl, a shell, the test types `ct switch` to change omp's model.
final class ClawdShots: XCTestCase {
    private let fixtures = ["omp", "claude"]
    private var prefix = ""

    override func setUpWithError() throws {
        prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["CLAWD_PREFIX"], "run this test through tools/clawd.sh")
    }

    /// Each mark in the strip, omp's again after each change of its model, and the cards' headers.
    @MainActor
    func testPictures() throws {
        let app = launch()
        try openControl(app)
        for name in fixtures {
            try showPill(app, name)
            keep(XCUIScreen.main.screenshot(), "01-strip-\(name)")
            keep(pill(app, name).screenshot(), "pill-\(name)")
        }

        for (model, name) in [
            ("openai-codex/gpt-6-sol", "omp-gpt"),
            ("openrouter/google/gemini-2.5-pro", "omp-gemini"),
            ("anthropic/claude-opus-5-5", "omp-claude"),
        ] {
            type(app, "ct switch \(model)")
            sleep(4)
            try showPill(app, "omp")
            keep(XCUIScreen.main.screenshot(), "02-strip-\(name)")
            keep(pill(app, "omp").screenshot(), "pill-\(name)")
        }

        // Opened beside the shell, the real omp gets a card, and both cards a header.
        let omp = pill(app, "omp")
        let terminal = app.textViews["terminal"].firstMatch
        omp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        XCTAssertTrue(app.descendants(matching: .any)["card.mac.\(prefix)-omp"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        keep(XCUIScreen.main.screenshot(), "03-card-headers")
    }

    @MainActor
    func testStates() throws {
        let app = launch()
        try prepare(app)
        keep(XCUIScreen.main.screenshot(), "state-idle")
        for (command, mark, shot) in [
            ("work", "working", "working"), ("rest", "finished", "done"), ("ask", "needs you", "needs-you"),
        ] {
            type(app, "ct \(command) claude")
            try state(app, mark)
            keep(XCUIScreen.main.screenshot(), "state-\(shot)")
        }
        type(app, "ct rest claude")
    }

    @MainActor
    func testRecording() throws {
        let wasOn = try setReduceMotion(false)
        defer {
            do { try setReduceMotion(wasOn) }
            catch { XCTFail("Could not restore Reduce Motion: \(error)") }
        }
        let app = launch()
        try openControl(app)
        type(app, "ct rest claude")
        try showPill(app, "claude")
        let frame = pill(app, "claude").frame
        let crop = XCTAttachment(string: "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)")
        crop.name = "recording-pill-points"
        crop.lifetime = .keepAlways
        add(crop)
        // A single shell command fixes the intervals across old and new builds; no model is prompted.
        type(app, "ct movie claude")
        sleep(26)
    }

    @MainActor
    private func prepare(_ app: XCUIApplication) throws {
        try openControl(app)
        type(app, "ct rest claude")
        try showPill(app, "claude")
        pill(app, "claude").tap()
        try openControl(app)
        try showPill(app, "claude")
        try state(app, "")
    }

    @MainActor
    private func state(_ app: XCUIApplication, _ expected: String) throws {
        try waitUntil(15, "the program stayed \(pill(app, "claude").value ?? "unknown"), wanted \(expected)") {
            pill(app, "claude").value as? String == expected
        }
    }

    @MainActor @discardableResult
    private func setReduceMotion(_ on: Bool) throws -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for label in ["Accessibility", "Motion"] {
            let row = settings.staticTexts[label].firstMatch
            guard row.waitForExistence(timeout: 10) else {
                throw Timeout(errorDescription: "Settings shows no \(label)")
            }
            row.tap()
        }
        let toggle = settings.switches["Reduce Motion"].firstMatch
        guard toggle.waitForExistence(timeout: 10) else {
            throw Timeout(errorDescription: "Settings shows no Reduce Motion")
        }
        let previous = try XCTUnwrap(toggle.value as? String)
        guard previous == "0" || previous == "1" else {
            throw Timeout(errorDescription: "Reduce Motion returned \(previous), not an on/off value")
        }
        let wanted = on ? "1" : "0"
        if previous != wanted {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        }
        try waitUntil(5, "Reduce Motion did not become \(wanted)") { toggle.value as? String == wanted }
        settings.terminate()
        return previous == "1"
    }

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-layout", "tabs"]
        app.launch()
        for name in fixtures {
            XCTAssertTrue(pill(app, name).waitForExistence(timeout: 30), "\(prefix)-\(name) never appeared")
        }
        return app
    }

    /// Opens the shell the `ct` commands go to and gives it the keyboard.
    @MainActor
    private func openControl(_ app: XCUIApplication) throws {
        let control = pill(app, "ctl")
        XCTAssertTrue(control.waitForExistence(timeout: 30), "\(prefix)-ctl never appeared")
        app.buttons["palette"].tap()
        app.typeText("\(prefix)-ctl")
        let row = app.descendants(matching: .any)["palette.open.mac.\(prefix)-ctl"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no control shell")
        row.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the shell never attached")
        terminal.tap()
        sleep(1)
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ command: String) {
        app.typeText(command)
        app.typeText("\r")
        sleep(1)
    }

    @MainActor
    private func pill(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["session.mac.\(prefix)-\(name)"].firstMatch
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

    /// Scrolls the strip until a fixture's pill sits at its left end, without opening it.
    @MainActor
    private func showPill(_ app: XCUIApplication, _ name: String) throws {
        let element = pill(app, name)
        try waitUntil(20, "\(name)'s icon never scrolled into view") {
            let frame = element.frame
            let left = app.buttons["host"].frame.maxX + 14
            let delta = left - frame.minX
            if abs(delta) < 8 { return true }
            // UIKit consumes the first few points before a drag becomes a scroll.
            let distance = min(350, max(-350, delta + (delta > 0 ? 12 : -12)))
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            return false
        }
    }

    /// Keeps a screenshot with the run. The whole screen comes from XCUIScreen: with the iPad lying in
    /// landscape, the app's own screenshot keeps only a portrait-sized corner of it.
    @MainActor
    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
