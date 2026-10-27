import XCTest

/// Sessions on a real device (tools/sessions.sh): two-word names for new sessions and the window keys. The
/// Mac session lhun-test-sessions-shell takes the screenshots: a test types the Mac's tools/snap.sh into
/// a shell, and the Mac photographs the iPad's screen a set time later, upright, as XCTest's own pictures
/// are not.
final class SessionsShots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The + glyph, ⌘T and the palette's New Session each start a session with two words for a name, open
    /// it, and give each a name no other session has. They are made on the server, which has no other
    /// sessions, so its strip shows these three pills alone.
    @MainActor
    func testNewSessionsGetTwoWordNames() throws {
        let app = launch()
        try open(app, "lhun-test-sessions-shell")
        let shot = try snap(app, "names", in: 60)
        try palette(app, "switch to server", run: "host.server")
        let plus = element(app, "new-session")
        XCTAssertTrue(holds(plus, "enabled == true"), "the server never came online")

        var names: [String] = []
        plus.tap()
        names.append(try opened(app, on: "server", besides: names))
        app.typeKey("t", modifierFlags: .command)
        names.append(try opened(app, on: "server", besides: names))
        try palette(app, "new session", run: "new")
        names.append(try opened(app, on: "server", besides: names))

        XCTAssertEqual(names.filter { $0.wholeMatch(of: /[a-z]+-[a-z]+/) == nil }, [], "names that are not two words")
        XCTAssertEqual(Set(names).count, names.count, "a name came twice: \(names)")
        // The newest session's shell lists the server's sessions under their pills.
        app.typeText("clear; tmux ls -F '#S'\r")
        hideKeyboard(app)
        sleep(2)
        XCTAssertLessThan(Date.now, shot, "the screenshot was taken before the pills were all there")
        Thread.sleep(until: shot.addingTimeInterval(4))
    }

    /// ⌃⇥ and ⌃⇧⇥ walk the open session's windows, round from the last to the first, and ⌥⌘] and ⌥⌘[ move
    /// the shown window and keep it shown. The fixture has windows alpha, beta and gamma with alpha shown,
    /// and tools/sessions.sh prints tmux's own list of them before and after. The pill tells which window
    /// shows by its index after the session's name. The terminal keeps the keys throughout, as it does
    /// while he types.
    @MainActor
    func testWindowKeysWalkAndMoveWindows() throws {
        let app = launch()
        let session = "lhun-test-sessions-win"
        try open(app, session)
        let pill = app.buttons["session.mac.\(session)"]
        XCTAssertTrue(holds(pill, "label CONTAINS %@", ":0"), "the session did not start at window 0: \(pill.label)")
        let steps: [(key: String, modifiers: XCUIElement.KeyModifierFlags, shows: Int)] = [
            ("\t", .control, 1), ("\t", .control, 2), ("\t", .control, 0),
            ("\t", [.control, .shift], 2), ("\t", [.control, .shift], 1),
            // beta, shown at 1, moves right to 2, then left to 1 and to 0, shown all along.
            ("]", [.command, .option], 2), ("[", [.command, .option], 1), ("[", [.command, .option], 0),
        ]
        for step in steps {
            app.typeKey(step.key, modifierFlags: step.modifiers)
            XCTAssertTrue(
                holds(pill, "label CONTAINS %@", ":\(step.shows)"),
                "\(step.modifiers.rawValue) \(step.key.debugDescription) did not show window \(step.shows): \(pill.label)"
            )
        }

        // The palette lists the windows in tmux's new order, beta shown and first, over tmux's own list.
        let shot = try snap(app, "windows", in: 15, then: "tmux list-windows")
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K opened no palette")
        field.typeText("windows")
        for (index, name) in ["beta", "alpha", "gamma"].enumerated() {
            XCTAssertTrue(holds(element(app, "palette.window.\(index)"), "label CONTAINS %@", name), "window \(index) is not \(name)")
        }
        XCTAssertEqual(element(app, "palette.window.0").value as? String, "current", "the moved window is not the shown one")
        XCTAssertTrue(element(app, "palette.move-window-right").exists, "no Move Window Right for the first window")
        XCTAssertFalse(element(app, "palette.move-window-left").exists, "Move Window Left offered for the first window")
        XCTAssertTrue(element(app, "palette.next-window").exists && element(app, "palette.previous-window").exists)
        XCTAssertLessThan(Date.now, shot, "the screenshot was taken before the palette listed the windows")
        Thread.sleep(until: shot.addingTimeInterval(4))
        app.typeKey("k", modifierFlags: .command)
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The probe's log names the sessions the run opened, so they can be killed afterwards.
        // Pills along the top whatever layout the device keeps, so the window pill is there to read.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Opens a session from its pill and waits until it takes typing.
    @MainActor
    private func open(_ app: XCUIApplication, _ session: String, on host: String = "mac") throws {
        let pill = app.buttons["session.\(host).\(session)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(session) never showed; tools/sessions.sh makes it")
        pill.tap()
        attached(app, session)
        // The first key after launch can go astray; this one types nothing that matters.
        app.typeKey("l", modifierFlags: .control)
    }

    /// Waits for a session the run has not seen yet to open on `host` and take typing, and returns its name.
    @MainActor
    private func opened(_ app: XCUIApplication, on host: String, besides seen: [String]) throws -> String {
        let prefix = "session.\(host)."
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", prefix))
        let deadline = Date.now.addingTimeInterval(30)
        var name: String?
        while Date.now < deadline, name == nil {
            name = open.allElementsBoundByIndex.map { String($0.identifier.dropFirst(prefix.count)) }
                .first { !seen.contains($0) }
            if name == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        let opened = try XCTUnwrap(name, "no new session opened; open ones: \(open.allElementsBoundByIndex.map(\.identifier))")
        attached(app, opened)
        return opened
    }

    @MainActor
    private func attached(_ app: XCUIApplication, _ session: String) {
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(session) never attached")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "\(session) never took the keyboard")
        // Keys typed while the keyboard slides in are lost.
        sleep(1)
    }

    /// Opens the palette, types `query` and taps the row with the command id `row`.
    @MainActor
    private func palette(_ app: XCUIApplication, _ query: String, run row: String) throws {
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K opened no palette")
        field.typeText(query)
        let command = element(app, "palette.\(row)")
        XCTAssertTrue(command.waitForExistence(timeout: 5), "the palette offered no \(row) for \(query)")
        command.tap()
    }

    /// Types into the open Mac session's shell: the Mac photographs the iPad's screen into `<name>.png` in
    /// the screenshot folder `delay` seconds on, the screen clears and `command` runs. Returns when the
    /// picture is taken, so the test can set the scene by then and wait it out.
    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String, in delay: Int, then command: String = "") throws -> Date {
        let environment = ProcessInfo.processInfo.environment
        let snap = try XCTUnwrap(environment["SESSIONS_SNAP"], "run this test through tools/sessions.sh")
        let shots = try XCTUnwrap(environment["SESSIONS_SHOTS"], "run this test through tools/sessions.sh")
        app.typeText("\(snap) \(shots)/\(name).png \(delay); clear; \(command)\r")
        return Date.now.addingTimeInterval(TimeInterval(delay))
    }

    /// The on-screen keyboard goes down, so it hides nothing.
    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        let keyboard = OnScreenKeyboard(app)
        if keyboard.up(within: 3) { keyboard.hide.tap() }
    }

    @MainActor
    private func holds(_ element: XCUIElement, _ format: String, _ arguments: CVarArg..., timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
