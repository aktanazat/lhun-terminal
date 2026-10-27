import XCTest

/// Session peek on a real device, against sessions tools/peek.sh starts: lhun-test-peek-diff,
/// lhun-test-peek-log and lhun-test-peek-colors on the Mac, lhun-test-peek-top on the server. A slow short
/// pull from the strip leaves the row of pictures open, a long one the grid of every session on both
/// hosts, and a tap opens a session from it. Then ⌘⇧\ opens and closes the grid twice in a row, the arrows
/// and Return open another session from it, typing narrows it, and the grid scrolls down to the server's
/// sessions before ⌘. closes it. Apart from that, the row and the grid open and close with the on-screen
/// keyboard up and with it down. The app logs every step to Documents/probe.jsonl, from which
/// tools/peek-check.py checks against tmux's own record that the open session kept its size while the
/// peek was open, and that the keyboard stepped aside for the peek and came back.
///
/// XCTest's synthetic Return and Escape never reach the app while the on-screen keyboard is up. Return
/// goes in as text instead, and Escape as ⌘. (Send Escape); both hand the terminal the byte the key would.
/// Guards:
/// - a slow short pull from the strip leaves the row open, a long one the grid
/// - the row and the grid show a picture of each session, the server's included
/// - a tapped card, or the highlighted one on Return, opens its session
/// - typing in the grid keeps only the sessions it matches; the first ⌘. empties it, the next closes the grid
/// - the open session's terminal keeps its size through the pull, with the keyboard up or down
/// - while the peek is out, neither the on-screen keyboard nor its key row is up
/// - a keyboard that was up comes back as the peek closes, and one that was down stays down
/// - the grid reaches the bottom of the screen, and opens at its top with no card cut at its edge
/// - each ⌘⇧\ that opens the grid moves the card out of its way, and the next one brings the card back
/// - once the peek is closed, an idle session presents no frames over 10 seconds
final class LhunPeek: XCTestCase {
    private static let diff = "lhun-test-peek-diff"
    private static let log = "lhun-test-peek-log"
    private static let top = "lhun-test-peek-top"
    private static let colors = "lhun-test-peek-colors"

    /// Defined by tools/peek.sh in lhun-test-peek-diff when the run saves pictures: typed with names and
    /// seconds (`shoot <name> <seconds>...`), it has the Mac photograph the device that many seconds later,
    /// which works while a finger is down and comes out upright.
    private let shoot = ProcessInfo.processInfo.environment["PEEK_SHOOT"]

    /// The peek has the screen below the strip to itself: while it is out, the on-screen keyboard and its
    /// key row step aside, so no key row lies over the row or the grid with the card's text showing through
    /// it. The row and the grid open once with the keyboard up and once with it down. With pictures, the
    /// test holds each pose over the second its picture is taken in.
    @MainActor
    func testPeekHasTheScreen() throws {
        let (app, probe, _) = try openDiff()
        let row = app.descendants(matching: .any)["peek.row"].firstMatch
        let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
        let card = app.descendants(matching: .any)["peek.card"].firstMatch
        let terminalView = app.textViews["terminal"].firstMatch
        let keyboard = OnScreenKeyboard(app)
        let strip = stripEnd(app)
        let size = { self.terminal(showing: Self.diff, in: probe).map { "\($0.cols)x\($0.rows)" } }
        // The first key XCTest sends after launch can go missing. Control-U at the empty prompt changes nothing.
        app.typeKey("u", modifierFlags: .control)

        // The keyboard up: the row, the grid, then the session with the keyboard back. Every key XCTest sends
        // hides the keyboard for a moment, so each half waits that out first. Each pull comes eight seconds or
        // more after the Mac's last picture: one taken just before a pull once left that peek without pictures,
        // every host unreachable.
        terminalView.tap()
        var start = shoot.map { type("\($0) row-keyboard-up 9 grid-keyboard-up 25 closed-keyboard-back 31", in: app) }
        sleep(2)  // the keyboard is back after the keys above
        XCTAssertTrue(keyboard.up(within: 10), "the key row never came up")
        sleep(1)  // the card has its height for the keyboard
        let up = try XCTUnwrap(keyboardTop(probe), "the probe never saw the keyboard")
        let sizeUp = size()
        pull(strip, 170)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a short pull did not leave the row open")
        XCTAssertTrue(
            eventually(within: 5) { !keyboard.isUp && (keyboardTop(probe) ?? up) > up }, "the keyboard stayed up under the row"
        )
        XCTAssertEqual(size(), sizeUp, "opening the row resized the session")
        XCTAssertTrue(showsPicture(self.card(app, "mac", Self.diff), within: 20), "the row showed no picture of \(Self.diff)")
        hold(from: start, until: 11)
        card.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "a tap on the card left the row open")
        XCTAssertTrue(
            eventually(within: 5) { keyboard.isUp && keyboardTop(probe) == up }, "the keyboard did not come back as the row closed"
        )
        hold(from: start, until: 19)
        pull(strip, 450)
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "a long pull did not open the grid")
        XCTAssertTrue(
            eventually(within: 5) { !keyboard.isUp && (keyboardTop(probe) ?? up) > up }, "the keyboard stayed up under the grid"
        )
        assertGridHasTheScreen(grid, in: app)
        XCTAssertTrue(showsPicture(self.card(app, "mac", Self.diff), within: 20), "the grid showed no picture of \(Self.diff)")
        hold(from: start, until: 27)
        closeGrid(grid)
        XCTAssertTrue(
            eventually(within: 5) { keyboard.isUp && keyboardTop(probe) == up }, "the keyboard did not come back as the grid closed"
        )
        XCTAssertEqual(size(), sizeUp, "the peek resized the session")
        hold(from: start, until: 36)

        // The keyboard down: it stays down through the row and the grid.
        start = shoot.map { type("\($0) row-keyboard-down 10 grid-keyboard-down 26", in: app) }
        sleep(2)  // the keyboard is back after the keys above
        XCTAssertTrue(keyboard.up(within: 10), "the key row never came back after typing")
        keyboard.hide.tap()
        XCTAssertTrue(keyboard.down(within: 5), "Hide Keyboard left the keyboard up")
        sleep(1)  // the card has its height without the keyboard
        let down = try XCTUnwrap(keyboardTop(probe), "the probe never saw the keyboard go")
        let sizeDown = size()
        pull(strip, 170)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a short pull did not leave the row open without the keyboard")
        XCTAssertTrue(
            showsPicture(self.card(app, "mac", Self.diff), within: 20), "the row showed no picture of \(Self.diff) without the keyboard"
        )
        hold(from: start, until: 12)
        card.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "a tap on the card left the row open without the keyboard")
        sleep(2)  // long enough for a keyboard to come up
        XCTAssertTrue(!keyboard.isUp && keyboardTop(probe) == down, "the keyboard came up as the row closed, though it was down")
        hold(from: start, until: 20)
        pull(strip, 450)
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "a long pull did not open the grid without the keyboard")
        assertGridHasTheScreen(grid, in: app)
        XCTAssertTrue(
            showsPicture(self.card(app, "mac", Self.diff), within: 20), "the grid showed no picture of \(Self.diff) without the keyboard"
        )
        hold(from: start, until: 28)
        closeGrid(grid)
        sleep(2)  // long enough for a keyboard to come up
        XCTAssertTrue(!keyboard.isUp && keyboardTop(probe) == down, "the keyboard came up as the grid closed, though it was down")
        XCTAssertEqual(size(), sizeDown, "the peek resized the session without the keyboard")
    }

    @MainActor
    func testPullOpenAndKeys() throws {
        let (app, probe, session) = try openDiff()
        attach("1-session")
        // The first key XCTest sends after launch can go missing. Control-U at the empty prompt changes nothing.
        app.typeKey("u", modifierFlags: .control)

        let row = app.descendants(matching: .any)["peek.row"].firstMatch
        let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
        let terminalView = app.textViews["terminal"].firstMatch
        let strip = stripEnd(app)

        // The Mac photographs the device five seconds after this command, while the pull below holds the card
        // part way down, and the hold lasts long enough that the pull's end comes eight seconds after that.
        if let shoot {
            terminalView.tap()
            app.typeText("\(shoot) 2-pulling 5\n")
        }
        sleep(2)  // the on-screen keyboard is back after the keys above, and the terminal has its size for it
        let before = try XCTUnwrap(terminal(showing: Self.diff, in: probe), "\(Self.diff) went away")
        strip.press(
            forDuration: 0.2, thenDragTo: strip.withOffset(CGVector(dx: 0, dy: 170)),
            withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: shoot == nil ? 0.5 : 11
        )
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a slow short pull from the strip did not leave the row open")
        let logCard = card(app, "mac", Self.log)
        XCTAssertTrue(showsPicture(logCard, within: 20), "\(Self.log) never showed a picture in the row")
        attach("3-row")
        let after = try XCTUnwrap(terminal(showing: Self.diff, in: probe), "\(Self.diff) left the screen")
        XCTAssertEqual("\(after.cols)x\(after.rows)", "\(before.cols)x\(before.rows)", "pulling the strip resized the session")

        strip.press(
            forDuration: 0.2, thenDragTo: strip.withOffset(CGVector(dx: 0, dy: 320)),
            withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.3
        )
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "a long pull did not open the grid")
        XCTAssertTrue(showsPicture(logCard, within: 10), "\(Self.log) never showed a picture in the grid")
        sleep(1)  // the card has finished sliding out of the picture
        attach("4-grid")

        logCard.tap()
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "opening a session left the grid up")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(Self.log) never attached")
        XCTAssertNotNil(terminal(showing: Self.log, in: probe), "tapping \(Self.log) did not open it")
        attach("5-opened")

        // ⌘⇧\ twice in a row: each time the grid opens with the open session highlighted and the card out of
        // its way, and the next ⌘⇧\ brings the card back to its place. The terminal sits at the top of its
        // card, so its top stays put as the keyboard comes and goes; a card left out of its place sits a whole
        // row of pictures lower, or more.
        let home = terminalView.frame.minY
        for round in 1...2 {
            try typeCommand("\\", [.command, .shift], in: app, probe: probe)
            XCTAssertTrue(grid.waitForExistence(timeout: 5), "⌘⇧\\ did not open the grid (round \(round))")
            XCTAssertTrue(eventually(within: 5) { logCard.isHittable }, "the card covers the grid (round \(round))")
            XCTAssertTrue(logCard.isSelected, "the open session's card is not highlighted (round \(round))")
            attach("\(4 + 2 * round)-shortcut-\(round)-open")
            try typeCommand("\\", [.command, .shift], in: app, probe: probe)
            XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "⌘⇧\\ left the grid up (round \(round))")
            XCTAssertTrue(
                eventually(within: 5) { abs(terminalView.frame.minY - home) < 20 },
                "the card did not come back to its place (round \(round))"
            )
            attach("\(5 + 2 * round)-shortcut-\(round)-closed")
        }

        // From the open session's card, the left arrow highlights the one before it, and Return opens that.
        try typeCommand("\\", [.command, .shift], in: app, probe: probe)
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "⌘⇧\\ did not open the grid for the arrows")
        XCTAssertTrue(eventually(within: 5) { logCard.isSelected }, "the open session's card is not highlighted for the arrows")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(eventually(within: 5) { !logCard.isSelected }, "the arrow did not move the highlight")
        let highlighted = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'peek.' AND selected == true")).firstMatch
        XCTAssertTrue(highlighted.waitForExistence(timeout: 5), "no card is highlighted after the arrow")
        let target = String(highlighted.identifier.split(separator: ".", maxSplits: 2).last ?? "")
        app.typeText("\r")
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "Return left the grid up")
        XCTAssertNotNil(terminal(showing: target, in: probe), "Return did not open \(target)")
        attach("10-return-opened")

        // Typing narrows the grid to the sessions that match, shown in a bar at its foot. The first ⌘. (Send
        // Escape) empties the bar and brings every session back; the grid stays up.
        try typeCommand("\\", [.command, .shift], in: app, probe: probe)
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "⌘⇧\\ did not open the grid for typing")
        let filter = app.descendants(matching: .any)["peek.filter"].firstMatch
        XCTAssertFalse(filter.exists, "the grid opened with its filter showing")
        app.typeText("peek-colors")
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "typing in the grid showed no filter")
        XCTAssertTrue(card(app, "mac", Self.colors).waitForExistence(timeout: 5), "the filter hid \(Self.colors)")
        XCTAssertTrue(logCard.waitForNonExistence(timeout: 5), "the filter kept \(Self.log)")
        XCTAssertFalse(card(app, "mac", Self.diff).exists, "the filter kept \(Self.diff)")
        attach("11-grid-filtered")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(filter.waitForNonExistence(timeout: 5), "⌘. left the filter up")
        XCTAssertTrue(grid.exists, "⌘. with the filter up closed the grid instead of emptying the filter")
        XCTAssertTrue(logCard.waitForExistence(timeout: 5), "emptying the filter did not bring \(Self.log) back")

        // The server's sessions come after the Mac's, below the first screen when the Mac has many, and the
        // grid makes a card only as it scrolls into view. Scroll down to them for the server's picture and a
        // picture of the grid with both hosts; ⌘. closes the grid from there.
        let topCard = card(app, "server", Self.top)
        for _ in 0..<6 where !topCard.isHittable { grid.swipeUp() }
        XCTAssertTrue(topCard.isHittable, "scrolling the grid never reached the server's sessions")
        XCTAssertTrue(showsPicture(topCard, within: 30), "the server's session never showed a picture")
        attach("12-grid-server")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "⌘. (Send Escape) left the grid up")

        // Back on the session the pull started from: no frames once it is idle.
        session.tap()
        XCTAssertNotNil(terminal(showing: Self.diff, in: probe), "\(Self.diff) never came back")
        sleep(5)
        let idleStart = try sample(probe)
        sleep(10)
        let idleEnd = try sample(probe)
        XCTAssertEqual((idleEnd["frames"] ?? -1) - (idleStart["frames"] ?? 0), 0, "an idle session presented frames after the peek closed")
    }

    /// Launches the app held at landscapeLeft and opens lhun-test-peek-diff from its pill, which comes back
    /// with the app and its probe.
    @MainActor
    private func openDiff() throws -> (app: XCUIApplication, probe: XCUIElement, pill: XCUIElement) {
        // Held at landscapeLeft, the screen's portrait pixels always hold the picture the same way round.
        let original = XCUIDevice.shared.orientation
        addTeardownBlock {
            await MainActor.run {
                if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(original) {
                    XCUIDevice.shared.orientation = original
                }
            }
        }
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let pill = app.descendants(matching: .any)["session.mac.\(Self.diff)"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(Self.diff) never appeared")
        pill.tap()
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(Self.diff) never attached")
        XCTAssertNotNil(terminal(showing: Self.diff, in: probe), "\(Self.diff) never showed")
        return (app, probe, pill)
    }

    /// The strip's empty end, just left of its buttons, where no pill takes the touch.
    @MainActor
    private func stripEnd(_ app: XCUIApplication) -> XCUICoordinate {
        let palette = app.descendants(matching: .any)["palette"].firstMatch
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: palette.frame.minX - 4, dy: palette.frame.midY))
    }

    /// Pulls the card down from the strip by `distance` points and lets go of it there, slowly enough that
    /// it settles by where it was let go: under 300 points the row, past that the grid.
    @MainActor
    private func pull(_ strip: XCUICoordinate, _ distance: CGFloat) {
        strip.press(
            forDuration: 0.2, thenDragTo: strip.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: XCUIGestureVelocity(distance < 300 ? 300 : 600), thenHoldForDuration: 0.5
        )
    }

    /// The grid has the screen below the strip: it reaches down to the bottom of the screen, and it opens
    /// at its top, with no card cut at its top edge.
    @MainActor
    private func assertGridHasTheScreen(_ grid: XCUIElement, in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(grid.frame.maxY, screen.maxY - 40, "the grid stops short of the bottom of the screen")
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'peek.mac.' OR identifier BEGINSWITH 'peek.server.'"))
            .allElementsBoundByIndex
        XCTAssertFalse(cards.isEmpty, "the grid shows no cards")
        let top = grid.frame.minY
        XCTAssertTrue(cards.allSatisfy { $0.frame.minY >= top }, "the grid opened scrolled down, its top row cut at the strip")
    }

    /// Closes the grid with a tap on its margin, beside the cards.
    @MainActor
    private func closeGrid(_ grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: 6)).tap()
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "a tap beside the cards left the grid up")
    }

    /// Types `command` and Return into the open session, and returns when the command went in.
    @MainActor
    private func type(_ command: String, in app: XCUIApplication) -> Date {
        app.typeText(command + "\n")
        return .now
    }

    /// Holds the pose until `seconds` after `start`, for the picture the Mac takes then; with no pictures
    /// to take, there is nothing to wait for.
    private func hold(from start: Date?, until seconds: TimeInterval) {
        guard let wait = start.map({ $0.addingTimeInterval(seconds).timeIntervalSinceNow }), wait > 0 else { return }
        Thread.sleep(forTimeInterval: wait)
    }

    @MainActor
    private func card(_ app: XCUIApplication, _ host: String, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["peek.\(host).\(name)"].firstMatch
    }

    /// Whether the card's picture arrives in time; the card says "waiting" until it does.
    @MainActor
    private func showsPicture(_ card: XCUIElement, within timeout: TimeInterval) -> Bool {
        eventually(within: timeout) { card.exists && card.value as? String == "shown" }
    }

    @MainActor
    private func eventually(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    /// The terminal on screen once the probe reports `session` there, or nil when it never does.
    @MainActor
    private func terminal(showing session: String, in probe: XCUIElement) -> (cols: Int, rows: Int)? {
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline {
            if let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
               let grid = (object["grids"] as? [[String: Any]])?.first,
               grid["session"] as? String == session,
               let cols = (grid["cols"] as? NSNumber)?.intValue, let rows = (grid["rows"] as? NSNumber)?.intValue {
                return (cols, rows)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// The top of the on-screen keyboard in screen points, as the app last saw it.
    @MainActor
    private func keyboardTop(_ probe: XCUIElement) -> Double? {
        let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        return (object?["keyboard"] as? NSNumber)?.doubleValue
    }

    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// The whole screen, upright. The app's own screenshot keeps only a portrait-sized corner of a
    /// landscape screen, and the screen's comes in its portrait pixels: held at landscapeLeft, the picture
    /// lies a quarter turn clockwise in them, so it is turned back. The pixels are read from the PNG, since
    /// XCTest's image carries an orientation of its own that the attachment's PNG drops.
    @MainActor
    private func attach(_ name: String) {
        let screen = XCUIScreen.main.screenshot()
        var image = screen.image
        if let pixels = UIImage(data: screen.pngRepresentation)?.cgImage, pixels.width < pixels.height {
            let upright = UIImage(cgImage: pixels, scale: image.scale, orientation: .left)
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            image = UIGraphicsImageRenderer(size: upright.size, format: format).image { _ in upright.draw(at: .zero) }
        }
        let shot = XCTAttachment(image: image, quality: .original)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
