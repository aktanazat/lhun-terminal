import XCTest

/// A session another screen has open, on a real device. tools/size.sh makes two tmux sessions on the Mac
/// for the run, <SIZE_PREFIX>-a and -b, and plays the other screen: a tmux client of the Mac's tmux in a
/// window whose size it sets. The test drives that screen by typing shell functions tools/size.sh defines
/// into the session it has open (`mac <session> <cols> <rows>`, `macsize <cols> <rows>`, `mackeys`,
/// `macquit`), and asks for pictures of the device's screen with `shoot <name> <seconds>`. tools/size.sh
/// records every client of the two sessions and lines each pose up with what tmux had then.
final class LhunSize: XCTestCase {
    /// The other screen had the session open at 160x45 before the app did. The card shows its window,
    /// whole once the keyboard is down (see `showsWhole`), and tmux keeps the window at 160x45. Take Size,
    /// in the palette, makes the iPad's size the session's; Give Back Size hands it back. When the other
    /// screen leaves, the iPad takes the size by itself.
    @MainActor
    func testJoinsASessionAnotherScreenSizes() throws {
        let (app, probe) = launch()
        let (a, _) = try fixtures()
        try open(app, a)
        let joined = settle(probe, "joined") { $0.first?.window == "160x45" && $0.first?.shared == true }
        assertFits(joined, "joined")

        app.typeText("shoot watching 8\r")
        hideKeyboard(app)
        let watching = settle(probe, "the whole window") { showsWhole($0, cols: 160, rows: 45) }
        assertFits(watching, "the whole window")
        sleep(8)

        take(app)
        let taken = settle(probe, "taken") { $0.first?.window == nil && $0.first?.shared == true }
        assertFits(taken, "taken")

        showKeyboard(app)
        app.typeText("shoot taken 8\r")
        hideKeyboard(app)
        let ownWhole = settle(probe, "taken, the keyboard down") { $0.first?.window == nil && size($0) != size(taken) }
        assertFits(ownWhole, "taken, the keyboard down")
        sleep(8)

        runCommand(app, typing: "give back", "give-back-size", "the palette offers no Give Back")
        let given = settle(probe, "given back") { $0.first?.window == "160x45" && $0.first?.shared == true }
        assertFits(given, "given back")

        showKeyboard(app)
        app.typeText("macquit\r")
        let alone = settle(probe, "the other screen left") { $0.first?.window == nil && $0.first?.shared == false }
        assertFits(alone, "the other screen left")
    }

    /// The app has the session to itself and sets its size until another screen opens it at 150x40; the
    /// card then shows that screen's window. Take, from the palette, makes the iPad's size win until
    /// someone types on the other screen, or resizes it, when the iPad lets the size go again. A window
    /// wider than the card shows whole in smaller text (see `showsWhole`). When the other screen leaves,
    /// the iPad takes the size back.
    @MainActor
    func testLetsAScreenThatComesLaterHaveTheSize() throws {
        let (app, probe) = launch()
        let (_, b) = try fixtures()
        try open(app, b)
        let alone = settle(probe, "alone") { $0.first?.window == nil && $0.first?.shared == false }
        assertFits(alone, "alone")

        app.typeText("mac \(b) 150 40\r")
        let joined = settle(probe, "another screen came") { $0.first?.window == "150x40" && $0.first?.shared == true }
        assertFits(joined, "another screen came")

        take(app)
        let taken = settle(probe, "taken") { $0.first?.window == nil && $0.first?.shared == true }
        assertFits(taken, "taken")
        showKeyboard(app)
        app.typeText("mackeys\r")
        let typed = settle(probe, "someone typed on the other screen") { $0.first?.window == "150x40" }
        assertFits(typed, "someone typed on the other screen")

        take(app)
        _ = settle(probe, "taken again") { $0.first?.window == nil && $0.first?.shared == true }
        showKeyboard(app)
        app.typeText("macsize 230 60\r")
        let grown = settle(probe, "the other screen grew") { $0.first?.window == "230x60" }
        assertFits(grown, "the other screen grew")

        app.typeText("shoot shrunk 8\r")
        hideKeyboard(app)
        let whole = settle(probe, "the whole wide window") { showsWhole($0, cols: 230, rows: 60) }
        assertFits(whole, "the whole wide window")
        XCTAssertLessThan(whole.first?.font ?? 0, alone.first?.font ?? 0, "a window wider than the card should show in smaller text")
        sleep(8)

        showKeyboard(app)
        app.typeText("macquit\r")
        let left = settle(probe, "the other screen left") { $0.first?.window == nil && $0.first?.shared == false }
        assertFits(left, "the other screen left")
        XCTAssertEqual(left.first?.font, alone.first?.font, "the text should be back at its size")
    }

    /// Held upright, which the windows' sizes are chosen for: on an iPad mini held sideways, even the
    /// smallest text can't fit 230x60's rows, and an earlier test can leave the simulator sideways.
    @MainActor
    private func launch() -> (app: XCUIApplication, probe: XCUIElement) {
        let original = XCUIDevice.shared.orientation
        addTeardownBlock { @MainActor in
            if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(original) {
                XCUIDevice.shared.orientation = original
            }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        return (app, probe)
    }

    /// Opens the session with its pill and waits for it to attach, then presses one key that types
    /// nothing: XCUITest's first key after a launch can go astray.
    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        let session = app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 30), "\(name) never appeared")
        session.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        terminal.tap()
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sleep(2)
    }

    /// Take Size from the palette.
    @MainActor
    private func take(_ app: XCUIApplication) {
        runCommand(app, typing: "take size", "take-size", "the palette offers no Take Size")
    }

    /// Runs the palette row `id`, typing `query` first: the palette brings the keyboard up, and in the
    /// whole list the row can sit under it, where a tap lands on a key.
    @MainActor
    private func runCommand(_ app: XCUIApplication, typing query: String, _ id: String, _ missing: String) {
        app.typeKey("k", modifierFlags: .command)
        app.typeText(query)
        let row = app.descendants(matching: .any)["palette.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), missing)
        row.tap()
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        XCTAssertTrue(OnScreenKeyboard(app).putDown(ifUpWithin: 10), "the keyboard never came up")
    }

    /// Brings the on-screen keyboard up with a tap on the terminal, unless it is up.
    @MainActor
    private func showKeyboard(_ app: XCUIApplication) {
        let keyboard = OnScreenKeyboard(app)
        if keyboard.isUp { return }
        app.textViews["terminal"].firstMatch.tap()
        XCTAssertTrue(keyboard.up(within: 10), "the keyboard never came up")
    }

    /// The sessions tools/size.sh made for this run: <SIZE_PREFIX>-a and -b.
    private func fixtures() throws -> (String, String) {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["SIZE_PREFIX"], "run this test through tools/size.sh")
        return ("\(prefix)-a", "\(prefix)-b")
    }

    /// One terminal on screen as the probe reports it.
    private struct Grid: Equatable, CustomStringConvertible {
        let session: String
        let cols: Int
        let rows: Int
        let font: Double
        let fit: String
        /// The other screen's window while the card shows it.
        let window: String?
        let shared: Bool

        var description: String {
            "\(session) \(cols)x\(rows) font \(font) window \(window ?? "own") shared \(shared): \(fit)"
        }
    }

    private func size(_ grids: [Grid]) -> String? {
        grids.first.map { "\($0.cols)x\($0.rows)" }
    }

    /// The smallest size the app draws another screen's window in (TerminalHost.smallestWatchFont).
    private static let smallestWatchFont = 8.0

    /// The other screen's `cols`×`rows` window shows on the card with every row: with every column too,
    /// or, where even the smallest size can't hold its width, at that size with the card full of columns.
    /// The rows rule out a pose the keyboard still shortens.
    private func showsWhole(_ grids: [Grid], cols: Int, rows: Int) -> Bool {
        guard let grid = grids.first, grid.window == "\(cols)x\(rows)", grid.rows == rows else { return false }
        return grid.cols == cols || (grid.font == Self.smallestWatchFont && grid.fit == "ok")
    }

    @MainActor
    private func grids(_ probe: XCUIElement) -> (t: Double, grids: [Grid])? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
              let t = (object["t"] as? NSNumber)?.doubleValue,
              let list = object["grids"] as? [[String: Any]]
        else { return nil }
        return (t, list.map { grid in
            Grid(
                session: grid["session"] as? String ?? "",
                cols: (grid["cols"] as? NSNumber)?.intValue ?? 0,
                rows: (grid["rows"] as? NSNumber)?.intValue ?? 0,
                font: (grid["font"] as? NSNumber)?.doubleValue ?? 0,
                fit: grid["fit"] as? String ?? "",
                window: grid["window"] as? String,
                shared: (grid["shared"] as? NSNumber)?.boolValue ?? false
            )
        })
    }

    /// Waits until two samples in a row report the same terminals on screen and `accept` takes them,
    /// then returns them. Fails with the last report when that never happens.
    @MainActor
    private func settle(
        _ probe: XCUIElement, _ point: String, timeout: TimeInterval = 40, until accept: ([Grid]) -> Bool
    ) -> [Grid] {
        let deadline = Date.now.addingTimeInterval(timeout)
        var previous: (t: Double, grids: [Grid])?
        while Date.now < deadline {
            if let sample = grids(probe), sample.t != previous?.t {
                if let previous, previous.grids == sample.grids, !sample.grids.isEmpty, accept(sample.grids) {
                    return sample.grids
                }
                previous = sample
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("\(point): the probe never settled on the expected state; last \(previous?.grids.description ?? "nothing")")
        return previous?.grids ?? []
    }

    private func assertFits(_ grids: [Grid], _ point: String) {
        XCTAssertFalse(grids.isEmpty, "\(point): no terminal on screen")
        XCTAssertEqual(grids.filter { $0.fit != "ok" }, [], "\(point): a terminal does not fit its card")
    }
}
