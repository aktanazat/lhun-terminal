import XCTest

/// The inbox on a device, against the sessions tools/inbox.sh makes: on the Mac a shell to start from, a
/// test run that failed and a sync, and on the server a backup and a deploy that asks before it goes on.
/// Run it through tools/inbox.sh, which makes them, photographs each step and checks the footprint.
final class LhunInbox: XCTestCase {
    private static let prefix = "lhun-test-inbox"
    private static let reading = "Reading its last 200 lines…"
    private static let writing = "Writing a summary…"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testInbox() throws {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the sessions' pills are there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-host", "server", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")

        // A session only counts as finished when Lhûn saw it at work: the backup and the sync work until
        // the test says go.
        try waitFor(element(app, "session.server.\(Self.prefix)-backup"), "working", timeout: 30)
        element(app, "palette").tap()
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "the palette never opened")
        query.typeText("switch")
        element(app, "palette.host.mac").tap()
        let sync = element(app, "session.mac.\(Self.prefix)-sync")
        try waitFor(sync, "working", timeout: 30)
        let home = element(app, "session.mac.\(Self.prefix)-home")
        XCTAssertTrue(home.waitForExistence(timeout: 10), "the home session never showed")
        home.tap()
        try attached(app)
        // tools/inbox.sh lets the backup finish, then the sync three seconds later.
        keep("go")
        try waitFor(sync, "finished", timeout: 30)
        let glyph = element(app, "inbox")
        try waitUntil(15, "the strip never counted the four sessions") { Int(glyph.value as? String ?? "") ?? 0 >= 4 }
        keep("1-strip")
        // The footprints tools/inbox.sh compares, before the inbox opens and after it closes, are both taken
        // with the keyboard away and after a card has come and gone: the palette's before, the inbox's after.
        // Closing either gives the keyboard back to the terminal and iPadOS sometimes puts it straight away
        // again, so only the inbox's own work differs between the two.
        hideKeyboard(app)
        try holdStill(probe)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5), "⌘K opened no palette")
        hideKeyboard(app)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForNonExistence(timeout: 5), "⌘K left the palette open")
        hideKeyboard(app)
        try holdStill(probe)
        // The inbox opened and closed once without a summary, so tools/inbox.sh can tell what reading the
        // screens and showing the rows leave from what a summary leaves.
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForExistence(timeout: 5), "⌘⇧I opened no inbox")
        let asking = row(app, "server", "deploy")
        try waitUntil(15, "the deploy's screen never showed") { asking.label.contains("migrations") }
        hideKeyboard(app)
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "⌘⇧I left the inbox open")
        hideKeyboard(app)
        try holdStill(probe)

        // ⌘⇧I lists both hosts' sessions that need him first, then the finished ones, each with the last
        // lines on its screen.
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForExistence(timeout: 5), "⌘⇧I opened no inbox")
        let build = row(app, "mac", "build")
        let deploy = row(app, "server", "deploy")
        let synced = row(app, "mac", "sync")
        let backup = row(app, "server", "backup")
        for (row, mark, line) in [
            (build, "needs you", "error: 1 of 48 tests failed"),
            (deploy, "needs you", "Apply 3 migrations to the production database? [y/N]"),
            (synced, "finished", "total size is 412.63G speedup is 128.11"),
            (backup, "finished", "snapshot 9b2d71c0 saved"),
        ] {
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(row.identifier) is not in the inbox")
            try waitUntil(10, "\(row.identifier) never showed \(line.debugDescription); it reads \(row.label.debugDescription)") {
                row.label.contains(line)
            }
            XCTAssertEqual(row.value as? String, mark, row.identifier)
        }
        for waiting in [build, deploy] {
            for done in [synced, backup] {
                XCTAssertLessThan(waiting.frame.minY, done.frame.minY, "\(waiting.identifier) is not above \(done.identifier)")
            }
        }
        hideKeyboard(app)
        keep("2-inbox")

        // Catch Up has the on-device model sum up the build, or says why it can't.
        element(app, "inbox.catchup.mac.\(Self.prefix)-build").tap()
        try summary(app, "mac", "build")
        keep("3-catch-up")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "⌘⇧I left the inbox open")
        hideKeyboard(app)
        try holdStill(probe)

        // A second Catch Up, on the backup, must keep no more memory than the first left.
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "the backup left the inbox")
        try readBoth(app, backup, showing: "snapshot")
        element(app, "inbox.catchup.server.\(Self.prefix)-backup").tap()
        try summary(app, "server", "backup")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "⌘⇧I left the inbox open")
        hideKeyboard(app)
        try holdStill(probe)

        // A row opens its session, which clears its mark; the open session is never in the inbox.
        glyph.tap()
        try readBoth(app, build, showing: "tests failed")
        build.tap()
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "opening the build left the inbox open")
        try attached(app)
        try waitUntil(10, "the probe never showed the build open") { selection(probe) == "\(Self.prefix)-build" }
        XCTAssertEqual(element(app, "session.mac.\(Self.prefix)-build").value as? String, "", "the open build still shows a mark")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "the backup left the inbox")
        XCTAssertFalse(build.exists, "the open build is in the inbox")
        try readBoth(app, backup, showing: "snapshot")
        backup.tap()
        try attached(app)
        try waitUntil(10, "the probe never showed the backup open") { selection(probe) == "\(Self.prefix)-backup" }
        XCTAssertEqual(element(app, "session.server.\(Self.prefix)-backup").value as? String, "", "the open backup still shows a mark")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(synced.waitForExistence(timeout: 5), "the sync left the inbox")
        try readBoth(app, synced, showing: "total size")
        synced.tap()
        try attached(app)
        try waitUntil(10, "the probe never showed the sync open") { selection(probe) == "\(Self.prefix)-sync" }
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(deploy.waitForExistence(timeout: 5), "the deploy, never opened, left the inbox")
        XCTAssertFalse(synced.exists, "the open sync is in the inbox")
        hideKeyboard(app)
        keep("4-cleared")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "⌘⇧I left the inbox open")

        // The palette's Catch Up on This Session lists the open session first, its summary under way.
        element(app, "palette").tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5), "the palette never opened")
        query.typeText("catch up")
        let catchUp = element(app, "palette.catch-up")
        XCTAssertTrue(catchUp.waitForExistence(timeout: 5), "the palette has no Catch Up on This Session")
        hideKeyboard(app)
        keep("5-palette-catch-up")
        catchUp.tap()
        XCTAssertTrue(synced.waitForExistence(timeout: 5), "Catch Up on This Session did not list the open sync")
        try summary(app, "mac", "sync")
        hideKeyboard(app)
        keep("6-catch-up-this-session")
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["inbox.query"].waitForNonExistence(timeout: 5), "⌘⇧I left the inbox open")
    }

    // MARK: Steps

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ host: String, _ session: String) -> XCUIElement {
        element(app, "inbox.\(host).\(Self.prefix)-\(session)")
    }

    /// Waits for the session's summary to be written, or for the reason it can't be, and records it in the
    /// result bundle, where tools/inbox.sh reads it.
    @MainActor
    private func summary(_ app: XCUIApplication, _ host: String, _ session: String) throws {
        let text = element(app, "inbox.summary.\(host).\(Self.prefix)-\(session)")
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Catch Up showed nothing for \(session)")
        try waitUntil(120, "the summary of \(session) never came; it reads \(text.label.debugDescription)") {
            ![Self.reading, Self.writing].contains(text.label)
        }
        XCTContext.runActivity(named: "summary of \(session): \(text.label)") { _ in }
    }

    @MainActor
    private func attached(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
    }

    /// Puts the on-screen keyboard down if it is up, or comes up within three seconds, so a screenshot shows
    /// the whole inbox and the probe's samples share one card size: Lhûn's key row has a Hide Keyboard button
    /// over a terminal, the system keyboard its own key over a field. On a simulator, with a hardware
    /// keyboard, a keyboard put down stays in the hierarchy below the screen, so a key that can be tapped is
    /// what shows it is up.
    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons.matching(NSPredicate(format: "identifier == 'Hide Keyboard' OR label ==[c] 'Hide keyboard'")).firstMatch
        let shows = { hide.exists && hide.isHittable }
        guard within(3, shows) else { return }
        hide.tap()
        XCTAssertTrue(within(10, { !shows() }), "the keyboard stayed up")
    }

    /// Whether `condition` holds within `seconds`.
    @MainActor
    private func within(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    /// Eight seconds of the probe's samples without a step, for tools/inbox.sh to read a settled footprint.
    @MainActor
    private func holdStill(_ probe: XCUIElement) throws {
        let start = probeTime(probe)
        try waitUntil(20, "the probe stopped sampling") { probeTime(probe) >= start + 8 }
    }

    /// Waits until the inbox shows both hosts' screens, the deploy's and `row`'s, so no row moves under a tap.
    @MainActor
    private func readBoth(_ app: XCUIApplication, _ row: XCUIElement, showing text: String) throws {
        let deploy = self.row(app, "server", "deploy")
        try waitUntil(10, "the inbox never showed both hosts' screens") {
            deploy.label.contains("migrations") && row.label.contains(text)
        }
    }

    @MainActor
    private func waitFor(_ pill: XCUIElement, _ mark: String, timeout: TimeInterval) throws {
        try waitUntil(timeout, "\(pill.identifier)'s mark never became \"\(mark)\"") { (pill.value as? String ?? "") == mark }
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ failure: @autoclosure () -> String, _ done: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !done() {
            guard Date.now < deadline else { throw Timeout(errorDescription: failure()) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private struct Timeout: LocalizedError {
        let errorDescription: String?
    }

    // MARK: Probe

    @MainActor
    private func sample(_ probe: XCUIElement) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
    }

    /// Seconds since launch of the latest sample.
    @MainActor
    private func probeTime(_ probe: XCUIElement) -> Double {
        (sample(probe)?["t"] as? NSNumber)?.doubleValue ?? 0
    }

    /// The open session's name, as the probe last saw it.
    @MainActor
    private func selection(_ probe: XCUIElement) -> String? {
        (sample(probe)?["selection"] as? [String: Any])?["name"] as? String
    }

    // MARK: Screenshots

    /// Has tools/inbox.sh act on `name`: photograph the device's screen as `name`.png, upright, or for
    /// "go", let the waiting sessions finish. The test asks with an empty file, take-inbox-<name>, in its
    /// own Documents and holds still until tools/inbox.sh answers with taken-inbox-<name>. The prefix keeps
    /// other tools' photographers off these requests.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-inbox-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-inbox-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/inbox.sh never answered \(name)")
    }
}
