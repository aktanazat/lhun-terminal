import UIKit
import XCTest

/// Walks Lhûn through the measurement points on a real device, against three tmux sessions on the Mac
/// that tools/probe.sh makes for the run, named after the caller (with tmux's status line off so nothing
/// redraws on its own). The app logs every point to Documents/probe.jsonl; tools/probe.sh copies it off.
/// Four guards close the run:
/// - an open session that receives nothing presents no frames over 10 seconds
/// - after a burst of emoji-heavy output, the terminal's local scrollback stays under the cap; tmux
///   owns history, so a local copy is memory spent on nothing
/// - with three sessions open, only the one on screen keeps a Metal renderer
/// - the sidebar draws its rows while it shows, and none once it is put away
///
/// A second test, run by tools/fit.sh, holds the terminal to its card. A third, run by tools/typing.sh,
/// times keys typed at a prompt. tools/perf.sh runs those with six more that measure what Lhûn costs:
/// launch, launch to a readable session, a quiet screen, a streaming one, one showing an agent at work,
/// and history scrolled back. `LHUN_TESTS=testBlinkingCursorRests tools/perf.sh` checks that a blinking
/// cursor stops drawing once the keys stop.
/// Every measured test holds the iPad in landscape. Metal draws a terminal into buffers the size of its
/// card, and upright the card is taller, so memory taken upright does not compare with memory taken
/// sideways. The probe logs the card at every sample, and tools/perf-summary.py --against refuses to
/// compare runs measured on different cards. Two more watch the palette over the on-screen keyboard: it
/// hangs between the strip and the keyboard, sideways and upright, and the session keeps its size while
/// the palette has the keyboard.
final class LhunProbe: XCTestCase {
    private static let scrollbackCapBytes = 64 * 1024
    private static let typedKeys = 50

    @MainActor
    func testFootprintAndGuards() throws {
        holdLandscape()
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"] + Self.launchArguments
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        assertLandscape(probe)
        sleep(8)

        let fixtures = try Self.fixtures()
        try open(app, fixtures[0])
        sleep(20)
        let idleFrames = try framesWhileNothingArrives(probe)
        let idleEnd = try sample(probe)

        terminal(app).tap()
        let tools = try XCTUnwrap(ProcessInfo.processInfo.environment["LHUN_TOOLS"], "run this test through tools/probe.sh")
        let stress = (tools as NSString).appendingPathComponent("stress.py").replacingOccurrences(of: "'", with: "'\\''")
        app.typeText("python3 '\(stress)'\n")
        let afterStress = try waitForQuiet(probe)

        XCUIDevice.shared.press(.home)
        sleep(14)
        app.activate()
        sleep(5)
        try open(app, fixtures[1])
        sleep(8)
        try open(app, fixtures[2])
        sleep(10)

        let threeOpen = try sample(probe)
        // Put away, the sidebar draws nothing.
        var putAway: [String: Int]?
        if Self.sidebarShown {
            app.buttons["sidebar-toggle"].tap()
            sleep(3)
            putAway = try sample(probe)
        }

        // tmux redraws only what is on screen, so the burst reaches the device as screen updates.
        XCTAssertGreaterThan(afterStress["bytesFed"] ?? 0, 50_000, "the stress output never arrived")
        XCTAssertEqual(idleFrames, 0, "an idle session presented frames (nil: the host sent it output in every window)")
        XCTAssertLessThanOrEqual(afterStress["scrollbackBytes"] ?? .max, Self.scrollbackCapBytes, "local scrollback grew past the cap")
        XCTAssertEqual(threeOpen["terminals"], 3, "three sessions should be open")
        XCTAssertLessThanOrEqual(threeOpen["metal"] ?? .max, 1, "a hidden session kept its Metal renderer")
        XCTAssertEqual((idleEnd["sidebarRows"] ?? 0) > 0, Self.sidebarShown, "whether the sidebar drew rows")
        if let putAway {
            XCTAssertEqual(putAway["sidebarRows"], 0, "the sidebar kept rows once put away")
        }
    }

    /// The terminal always fits its card: its view lies inside the card, holds whole cells only, and
    /// leaves no room for another column or row. Checked where it once spilled past the card's edges (a
    /// session opened with the + glyph), after zooming three steps in and back out with the keyboard, and
    /// after the device turns. tools/fit.sh runs it and checks tmux was sent the size the probe reports.
    @MainActor
    func testTerminalFitsItsCard() throws {
        let (app, probe, terminal) = launchIntoNewSession()
        let opened = settle(probe, "a new session")
        assertFits(opened, "a new session")
        photograph(app, terminal, "new-session")

        // Zooms away from the nearer end of the allowed sizes and back, leaving the size as it was.
        let start = opened.first?.font ?? 0
        let step = start <= 25 ? 1 : -1
        let (inKey, outKey) = step == 1 ? ("=", "-") : ("-", "=")
        for count in 1...3 {
            terminal.typeKey(inKey, modifierFlags: .command)
            _ = settle(probe, "zoom step \(count)", timeout: 20) { $0.first?.font == start + step * count }
        }
        assertFits(settle(probe, "zoomed"), "zoomed three steps")
        photograph(app, terminal, "zoomed")
        for count in 1...3 {
            terminal.typeKey(outKey, modifierFlags: .command)
            _ = settle(probe, "zoom back step \(count)", timeout: 20) { $0.first?.font == start + step * (3 - count) }
        }
        let back = settle(probe, "zoomed back")
        assertFits(back, "zoomed back")

        // Turning changes the card's width. Its height says little: it also moves with the keyboard.
        let width = back.first?.card.first
        let window = app.windows.firstMatch.frame
        let wasLandscape = window.width > window.height
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = wasLandscape ? .portrait : .landscapeLeft
        let turned = settle(probe, "turned") { $0.first.map { $0.card.first != width } ?? false }
        assertFits(turned, "after the device turned")
        photograph(app, terminal, wasLandscape ? "portrait" : "landscape")
        XCUIDevice.shared.orientation = switch original {
        case .landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown: original
        default: wasLandscape ? .landscapeLeft : .portrait
        }
    }

    /// The palette over the on-screen keyboard hangs just under the strip and ends above the keyboard,
    /// scrolling the rest of its list, held sideways and upright. The smallest iPad held sideways leaves it
    /// the least room, the keyboard taking over half the screen: there it once rose over the strip and ran
    /// under the keyboard. ⌘K opens it: on a simulator the on-screen keyboard comes up only after a typed key.
    @MainActor
    func testPaletteHangsBetweenTheStripAndTheKeyboard() throws {
        let (app, probe, terminal) = launchIntoNewSession()
        let original = XCUIDevice.shared.orientation
        addTeardownBlock { @MainActor in
            if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(original) {
                XCUIDevice.shared.orientation = original
            }
        }
        let strip = app.descendants(matching: .any)["strip"].firstMatch
        let card = app.descendants(matching: .any)["palette.query.card"].firstMatch
        for (pose, orientation) in [("sideways", UIDeviceOrientation.landscapeLeft), ("upright", .portrait)] {
            XCUIDevice.shared.orientation = orientation
            terminal.tap()
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(card.waitForExistence(timeout: 5), "\(pose): ⌘K opened no palette")
            guard let open = try overKeyboard(card, probe, above: app.windows.firstMatch.frame.maxY, pose) else { return }
            XCTAssertGreaterThanOrEqual(
                open.card.minY, strip.frame.maxY, "\(pose): the palette rose over the strip; card \(open.card), strip \(strip.frame)"
            )
            XCTAssertLessThanOrEqual(
                open.card.maxY, open.keyboard, "\(pose): the palette ran under the keyboard; card \(open.card), keyboard top \(open.keyboard)"
            )
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(card.waitForNonExistence(timeout: 5), "\(pose): ⌘K left the palette open")
        }
    }

    /// A session opened from the palette takes typing at once, as when ⌘K, its name and Return open it,
    /// though its terminal comes on screen only as the palette goes. Two new sessions from the + glyph,
    /// then the palette back to the first by name, and keys typed straight away.
    @MainActor
    func testSessionOpenedFromThePaletteTakesTyping() throws {
        let (app, probe, terminal) = launchIntoNewSession()
        let first = try XCTUnwrap(openSession(probe), "the probe names no open session")
        app.buttons["new-session"].tap()
        XCTAssertNotNil(openSession(probe) { $0 != first }, "the + glyph never opened a second session")
        app.descendants(matching: .any)["palette"].firstMatch.tap()
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "the palette never opened")
        query.typeText(first)
        let row = app.descendants(matching: .any)["palette.open.mac.\(first)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette lists no \(first)")
        row.tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5), "opening \(first) left the palette open")
        XCTAssertNotNil(openSession(probe) { $0 == first }, "the palette never opened \(first)")
        let sent = try sample(probe)["sentCount"] ?? 0
        terminal.typeText("true")
        let deadline = Date.now.addingTimeInterval(10)
        while try sample(probe)["sentCount"] ?? 0 < sent + 4, Date.now < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertGreaterThanOrEqual(try sample(probe)["sentCount"] ?? 0, sent + 4, "the keys typed never reached \(first)")
    }

    /// Opening and closing the palette over the on-screen keyboard sends tmux no size. The palette's
    /// search field takes the keyboard without the key row, so the keyboard drops and the card grows;
    /// closing hands the keyboard to the terminal, which brings the row back, and the card shrinks again.
    /// The terminal keeps its grid from the palette opening until the keyboard is back and still. Touches
    /// only: a key XCTest types plugs in a hardware keyboard for a moment, which takes the key row away. A
    /// simulator has a hardware keyboard throughout, so there the keyboard may not move at all, and the
    /// test skips.
    @MainActor
    func testPaletteOverTheKeyboardKeepsTheGrid() throws {
        let (app, probe, terminal) = launchIntoNewSession()
        terminal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the on-screen keyboard never came up")
        let keyRow = app.buttons["Escape"].exists ? "with the key row" : "without the key row"
        let before = try XCTUnwrap(typing(probe, "the keyboard up") { $0.focused && $0.keyboard != nil })
        app.descendants(matching: .any)["palette"].firstMatch.tap()
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "the palette never opened")
        let open = try XCTUnwrap(typing(probe, "the palette open") { !$0.focused })
        // The dimmed backdrop beside the card, which keeps 16 points from the screen's sides, closes it.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 8, dy: query.frame.midY)).tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5), "a tap on the backdrop left the palette open")
        let after = try XCTUnwrap(typing(probe, "the palette closed") { $0.focused && $0.keyboard == before.keyboard })
        let story = "keyboard up \(keyRow): \(before); palette open: \(open); closed: \(after)"
        if open.keyboard == before.keyboard {
            throw XCTSkip("the keyboard kept its place under the palette, so there was no move to hold the grid through. \(story)")
        }
        XCTAssertEqual(after.resizes, before.resizes, "the palette resized the session. \(story)")
        XCTAssertEqual([after.cols, after.rows], [before.cols, before.rows], "the palette left another grid. \(story)")
    }

    /// The path picker, the inbox and the theme picker, each opened from the palette and closed by a tap
    /// beside it over the on-screen keyboard, give the terminal the keyboard straight from their field: it
    /// brings the key row back without leaving the screen, and tmux is sent no size. UIKit can report an
    /// intermediate keyboard height while swapping input views; only going off screen counts as hiding.
    @MainActor
    func testPathPickerHandsTheKeyboardStraightBack() throws {
        try handsTheKeyboardStraightBack(opening: "insert-path", typing: "insert", field: "paths.query")
    }

    @MainActor
    func testInboxHandsTheKeyboardStraightBack() throws {
        try handsTheKeyboardStraightBack(opening: "inbox", typing: "inbox", field: "inbox.query")
    }

    @MainActor
    func testThemePickerHandsTheKeyboardStraightBack() throws {
        try handsTheKeyboardStraightBack(opening: "theme", typing: "theme", field: "themes.query")
    }

    /// Five launches timed by XCTest to the first frame, after one it throws away. The probe logs each
    /// launch too, with the milliseconds from the process starting until Lhûn is active.
    @MainActor
    func testLaunch() {
        holdLandscape()
        let app = XCUIApplication()
        app.launchArguments = Self.arguments("launch")
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    /// Seven launches with a session open, each timed by the probe from the process starting to the first
    /// frame that shows the session with text (`readable`) and to the first that shows tmux's own redraw of
    /// it (`current`). The first opens the session from its pill and is not counted. Each after it leaves
    /// for the home screen first and then starts Lhûn cold, the way iOS ends an app left in the background.
    @MainActor
    func testLaunchToReadable() throws {
        let (app, _) = launch("readable")
        try open(app, Self.fixtures()[0])
        // Without `-selection`, each launch opens the session the one before left open.
        app.launchArguments = ["-keySeen", "YES", "-host", "mac", "-probe", "YES", "-probeRun", "readable"]
        for _ in 0..<6 {
            XCUIDevice.shared.press(.home)
            sleep(3)
            app.launch()
            XCTAssertTrue(terminal(app).waitForExistence(timeout: 15), "the session did not open at launch")
            XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
            sleep(2)
        }
    }

    /// A session streaming a steady build log, 1 MB over 90 seconds from tools/stream.py, measured in
    /// the probe's window once the log flows.
    @MainActor
    func testOutputStream() throws {
        let (app, probe) = launch("stream")
        try open(app, Self.fixtures()[0])
        sleep(5)
        terminal(app).tap()
        app.typeText("clear; python3 \(try Self.tools())/stream.py\n")
        sleep(5)
        measureWindow(app)
        XCTAssertGreaterThan(try waitForQuiet(probe)["bytesFed"] ?? 0, 500_000, "the stream never reached the device")
    }

    /// A session showing only a status line redrawn in place twenty times a second, the way a coding agent
    /// shows it is working (tools/stream.py with no log), measured in the probe's window.
    @MainActor
    func testWorkingSpinner() throws {
        let (app, probe) = launch("spinner")
        try open(app, Self.fixtures()[1])
        sleep(5)
        terminal(app).tap()
        app.typeText("clear; python3 \(try Self.tools())/stream.py 45 0\n")
        sleep(5)
        measureWindow(app)
        XCTAssertGreaterThan(try lastWindow(probe)["frames"] ?? 0, 0, "the status line never reached the screen")
    }

    /// Three sessions open and the one on screen quiet. Nothing on screen changes, so it draws nothing. Frames
    /// are judged over 10 seconds in which nothing reached the session (framesWhileNothingArrives): tmux
    /// repaints every attached client whenever a pane on its server sets an option, and Lhûn rightly draws
    /// that repaint. The window after it only measures what a quiet screen costs; on a Mac where agents work
    /// it can catch such a repaint, so its frames are not judged.
    @MainActor
    func testQuietSessions() throws {
        let (app, probe) = launch("quiet")
        for name in try Self.fixtures() { try open(app, name) }
        sleep(10)
        let settled = try XCTUnwrap(
            framesWhileNothingArrives(probe),
            "the host never went quiet: output reached the session in six 10-second stretches in a row"
        )
        XCTAssertEqual(settled, 0, "a quiet screen presented frames while nothing arrived")
        measureWindow(app)
    }

    /// Fast swipes back through history, in a session tools/perf.sh fills with 3,000 lines. History opens
    /// with a swipe down on the terminal; five more go further back each time, reading older lines in as
    /// they near the top.
    @MainActor
    func testScrollingHistory() throws {
        let (app, _) = launch("scroll")
        let session = try XCTUnwrap(ProcessInfo.processInfo.environment["PERF_HISTORY"], "run this test through tools/perf.sh")
        try open(app, session)
        sleep(3)
        terminal(app).swipeDown(velocity: .fast)
        let history = app.textViews["history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
        sleep(3)
        measureWindow(app, [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            for _ in 0..<5 { history.swipeDown(velocity: .fast) }
        }
    }

    /// Has the probe open its 30-second window, does `actions` at the start of it, and has XCTest measure
    /// the same stretch: the frames and hitches in the window, and the app's CPU from outside. XCTest runs
    /// the block twice and reports the second; the probe logs both.
    @MainActor
    private func measureWindow(_ app: XCUIApplication, _ metrics: [any XCTMetric] = [], actions: () -> Void = {}) {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        let window = XCTOSSignpostMetric(subsystem: "com.aktanazat.lhun", category: "probe", name: "window")
        measure(metrics: [window, XCTHitchMetric(application: app), XCTCPUMetric(application: app)] + metrics, options: options) {
            let opened = Date.now
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.aktanazat.lhun.probe.window" as CFString), nil, nil, true
            )
            actions()
            Thread.sleep(until: opened.addingTimeInterval(32))
        }
    }

    /// What the probe's last window cost, as it logs it once the window closes.
    @MainActor
    private func lastWindow(_ probe: XCUIElement) throws -> [String: Int] {
        sleep(2)
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
        let window = try XCTUnwrap(object["lastWindow"] as? [String: Any], "the probe logged no window")
        return window.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    @MainActor
    private func launch(_ run: String) -> (app: XCUIApplication, probe: XCUIElement) {
        holdLandscape()
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(run)
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        assertLandscape(probe)
        return (app, probe)
    }

    /// Holds the iPad in landscape until the test ends, when Lhûn is closed first, so the probe logs nothing
    /// upright, and the iPad then turns back the way it was.
    @MainActor
    private func holdLandscape() {
        let original = XCUIDevice.shared.orientation
        addTeardownBlock {
            await MainActor.run {
                XCUIApplication().terminate()
                if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(original) {
                    XCUIDevice.shared.orientation = original
                }
            }
        }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Fails unless the probe reports Lhûn standing in landscape within ten seconds, which the rotation
    /// lock can stop.
    @MainActor
    private func assertLandscape(_ probe: XCUIElement) {
        let deadline = Date.now.addingTimeInterval(10)
        var orientation = 0
        repeat {
            orientation = (try? sample(probe)["orientation"]) ?? 0
            if UIInterfaceOrientation(rawValue: orientation)?.isLandscape == true { return }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date.now < deadline
        XCTFail("Lhûn stands in interface orientation \(orientation), not landscape; is the iPad's rotation locked?")
    }

    /// The launch arguments of a measured run, which the probe logs as `run`.
    private static func arguments(_ run: String) -> [String] {
        ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-probeRun", run]
    }

    /// This checkout's tools folder on the Mac, which tools/perf.sh passes in.
    private static func tools() throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment["PERF_TOOLS"], "run this test through tools/perf.sh")
    }

    /// Times keys typed at a zsh prompt on the Mac, from the key going down to the frame that shows its
    /// echo. The keys go in 0.7 seconds apart, far longer than an echo takes, so each echo pairs with its
    /// own key, and the test leaves the app alone in between: a query runs on the app's main thread and
    /// would slow the very trip being timed. The probe logs each key's trip; tools/typing.sh sums them up.
    /// Every letter must be typed straight from its key press: the system's text input costs 40 ms a key.
    @MainActor
    func testTypingLatency() throws {
        holdLandscape()
        let (app, probe, terminal) = launchIntoNewSession()
        assertLandscape(probe)
        terminal.tap()
        sleep(3)
        let letters = Array("thequickbrownfoxjumpsoverthelazydog")
        for index in 0..<Self.typedKeys {
            app.typeKey(String(letters[index % letters.count]), modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.7)
        }
        let deadline = Date.now.addingTimeInterval(10)
        var timed = try sample(probe)["keys"] ?? 0
        while timed < Self.typedKeys, Date.now < deadline {
            sleep(1)
            timed = try sample(probe)["keys"] ?? 0
        }
        XCTAssertEqual(timed, Self.typedKeys, "keys whose echo reached the screen")
        XCTAssertEqual(try sample(probe)["keysDirect"], timed, "keys typed straight from the press")
    }

    /// A cursor the program asks to blink stops 10 seconds after the last key, so a session left with one
    /// draws nothing, and blinks again at the next key. Each blink is a frame drawn.
    @MainActor
    func testBlinkingCursorRests() throws {
        let (app, probe, terminal) = launchIntoNewSession()
        terminal.tap()
        sleep(3)
        app.typeText("printf '\\e[1 q'\n")
        sleep(12)
        let resting = try XCTUnwrap(framesWhileNothingArrives(probe), "the host never went quiet")
        XCTAssertEqual(resting, 0, "a blinking cursor kept drawing after the keys stopped")

        app.typeKey(" ", modifierFlags: [])
        sleep(1)
        let start = try sample(probe)
        sleep(4)
        let end = try sample(probe)
        XCTAssertGreaterThanOrEqual(
            (end["frames"] ?? 0) - (start["frames"] ?? 0), 4, "the cursor did not blink again after a key"
        )
    }

    /// Launches Lhûn with the probe on and opens a new session on the Mac with the + glyph.
    @MainActor
    private func launchIntoNewSession() -> (app: XCUIApplication, probe: XCUIElement, terminal: XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"] + Self.launchArguments
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let newSession = app.buttons["new-session"]
        XCTAssertTrue(newSession.wait(for: \.isEnabled, toEqual: true, timeout: 30), "the + glyph never came on")
        newSession.tap()
        let terminal = self.terminal(app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "the new session never showed a terminal")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the new session never attached")
        return (app, probe, terminal)
    }

    /// Opens a new session, brings up the on-screen keyboard and runs the palette's `command` by touch,
    /// found by tapping out `query`, then closes what it opened, the search field named `field`, with a tap
    /// on the backdrop.
    @MainActor
    private func handsTheKeyboardStraightBack(opening command: String, typing query: String, field: String) throws {
        let (app, probe, terminal) = launchIntoNewSession()
        terminal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the on-screen keyboard never came up")
        let before = try XCTUnwrap(typing(probe, "the keyboard up") { $0.focused && $0.keyboard != nil })
        app.descendants(matching: .any)["palette"].firstMatch.tap()
        XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 5), "the palette never opened")
        // Only the rows in sight are drawn, so the command's name narrows the list first, tapped out on the
        // on-screen keyboard: a key XCTest types plugs in a hardware keyboard for a moment.
        for letter in query {
            let key = app.keyboards.keys[String(letter)]
            XCTAssertTrue(key.waitForExistence(timeout: 5), "the on-screen keyboard has no \(letter) key")
            key.tap()
        }
        let row = app.descendants(matching: .any)["palette.\(command)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no \(command)")
        let card = app.descendants(matching: .any)["palette.query.card"].firstMatch
        for _ in 0..<8 where !row.isHittable { card.swipeUp(velocity: .slow) }
        row.tap()
        let query = app.textFields[field]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "\(command) opened no \(field)")
        let open = try XCTUnwrap(typing(probe, "\(command) open") { !$0.focused })
        // The dimmed backdrop beside the card, which keeps 16 points from the screen's sides, closes it.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 8, dy: query.frame.midY)).tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5), "a tap on the backdrop left \(field) open")
        let after = try XCTUnwrap(typing(probe, "\(command) closed") { $0.focused && $0.keyboard == before.keyboard })
        let story = "keyboard up: \(before); \(command) open: \(open); closed: \(after)"
        if open.keyboard == before.keyboard {
            throw XCTSkip("the keyboard kept its place under \(field), so there was no move to hand back. \(story)")
        }
        XCTAssertEqual(after.keyboardHides, open.keyboardHides, "the keyboard went away before the terminal took it. \(story)")
        XCTAssertEqual(after.resizes, before.resizes, "closing \(field) resized the session. \(story)")
    }

    /// Opens a session on the Mac from its pill, or, in the sidebar layout, from its row, found through the
    /// filter: a row out of sight is not drawn.
    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        let pill = app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
        let filter = app.textFields["sidebar.filter"]
        let deadline = Date.now.addingTimeInterval(30)
        while !pill.exists, !filter.exists, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if filter.exists {
            let clear = app.buttons["sidebar.filter.clear"]
            if clear.exists { clear.tap() }
            filter.tap()
            filter.typeText(name)
            let row = app.buttons["sidebar.mac.\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(name) never appeared in the sidebar")
            row.tap()
        } else {
            XCTAssertTrue(pill.exists, "\(name) never appeared")
            pill.tap()
        }
        XCTAssertTrue(terminal(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
    }

    /// The open session's terminal. The program icons on the session list and the card's header carry the
    /// same identifier, and the first match by identifier alone is the header's icon: a swipe down on it
    /// travels a few points and opens nothing.
    @MainActor
    private func terminal(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["terminal"].firstMatch
    }

    /// More launch arguments from LHUN_LAUNCH_ARGS: `-compactLayout YES` from tools/fit.sh, or
    /// `-layout sidebar -sidebar YES` to measure with the sidebar shown. Without a layout of its own the run
    /// has pills along the top whatever layout the device keeps, so the strip and the pills are there.
    private static var launchArguments: [String] {
        let given = (ProcessInfo.processInfo.environment["LHUN_LAUNCH_ARGS"] ?? "").split(separator: " ").map(String.init)
        return given.contains("-layout") ? given : ["-layout", "tabs"] + given
    }

    /// The run shows the sidebar: launched with `-layout sidebar -sidebar YES` on an iPad held sideways.
    private static var sidebarShown: Bool {
        let arguments = launchArguments
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        return value("-layout") == "sidebar" && value("-sidebar") == "YES"
    }

    /// The sessions tools/probe.sh made for this run: <PROBE_PREFIX>-proof, -proof2 and -proof3.
    private static func fixtures() throws -> [String] {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["PROBE_PREFIX"], "run this test through tools/probe.sh")
        return ["proof", "proof2", "proof3"].map { "\(prefix)-\($0)" }
    }

    /// Waits until no output has arrived for 5 seconds, then returns that sample.
    @MainActor
    private func waitForQuiet(_ probe: XCUIElement) throws -> [String: Int] {
        var last = try sample(probe)
        var quietSeconds = 0
        for _ in 0..<600 where quietSeconds < 5 {
            sleep(1)
            let next = try sample(probe)
            quietSeconds = next["bytesFed"] == last["bytesFed"] && (next["bytesFed"] ?? 0) > 0 ? quietSeconds + 1 : 0
            last = next
        }
        return last
    }

    /// The frames the open session presented over 10 seconds in which it received nothing, from a second
    /// before them to their end. tmux repaints every attached client whenever any pane on its server sets
    /// an option, as lhun-tap does at each change of a program's status, so on a Mac where agents work a
    /// window can catch a repaint of the idle session; that says nothing about Lhûn, and the next window
    /// is taken. Nil when six windows in a row all received output.
    @MainActor
    private func framesWhileNothingArrives(_ probe: XCUIElement) throws -> Int? {
        for _ in 0..<6 {
            let before = try sample(probe)
            sleep(1)
            let start = try sample(probe)
            sleep(10)
            let end = try sample(probe)
            guard end["bytesFed"] == before["bytesFed"] else { continue }
            return (end["frames"] ?? -1) - (start["frames"] ?? 0)
        }
        return nil
    }

    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Int] {
        let label = probe.label
        let object = try JSONSerialization.jsonObject(with: Data(label.utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// Waits up to 30 seconds for the probe to name an open session `accept` takes, and returns its name.
    @MainActor
    private func openSession(_ probe: XCUIElement, until accept: (String) -> Bool = { _ in true }) -> String? {
        let deadline = Date.now.addingTimeInterval(30)
        repeat {
            if let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
               let name = (object["selection"] as? [String: Any])?["name"] as? String, !name.isEmpty, accept(name) {
                return name
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date.now < deadline
        return nil
    }

    /// Waits until two samples in a row report the same terminals on screen and `accept` takes them,
    /// then returns them. Fails with the last report when that never happens.
    @MainActor
    private func settle(
        _ probe: XCUIElement, _ point: String, timeout: TimeInterval = 40,
        until accept: ([Grid]) -> Bool = { _ in true }
    ) -> [Grid] {
        let deadline = Date.now.addingTimeInterval(timeout)
        var previous: (t: Double, grids: [Grid])?
        while Date.now < deadline {
            if let sample = probeGrids(probe), sample.t != previous?.t {
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

    /// Waits for the on-screen keyboard to come up, its top above `bottom`, and for it and the card to hold
    /// still for a second, then returns the card's frame and the keyboard's top: the probe's, from the frame
    /// iOS gives the keyboard. Fails with the last of both after 15 seconds.
    @MainActor
    private func overKeyboard(
        _ card: XCUIElement, _ probe: XCUIElement, above bottom: CGFloat, _ point: String
    ) throws -> (card: CGRect, keyboard: CGFloat)? {
        let deadline = Date.now.addingTimeInterval(15)
        var held: (card: CGRect, keyboard: Int?, since: Date)?
        while Date.now < deadline {
            let now = (card: card.frame, keyboard: try sample(probe)["keyboard"])
            if let held, held.card == now.card, held.keyboard == now.keyboard {
                if let keyboard = now.keyboard, CGFloat(keyboard) < bottom, Date.now.timeIntervalSince(held.since) >= 1 {
                    return (now.card, CGFloat(keyboard))
                }
            } else {
                held = (now.card, now.keyboard, .now)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail(
            "\(point): the on-screen keyboard never came up and held still under the palette; last card \(held?.card ?? .null), "
                + "keyboard top \(held?.keyboard.map(String.init) ?? "none"), screen bottom \(bottom)"
        )
        return nil
    }

    /// The open terminal as the probe reports it, with the on-screen keyboard.
    private struct Typing: Equatable, CustomStringConvertible {
        let cols: Int
        let rows: Int
        /// Sizes sent to tmux after the first.
        let resizes: Int
        /// Whether it has the keyboard.
        let focused: Bool
        /// The keyboard's top in points, as its last move left it; nil before its first move.
        let keyboard: Int?
        /// The number of times the keyboard has left the screen since launch.
        let keyboardHides: Int

        var description: String {
            "\(cols)x\(rows), \(resizes) resizes, \(focused ? "typing" : "not typing"), keyboard top \(keyboard.map(String.init) ?? "unknown")"
                + ", hidden \(keyboardHides) times"
        }
    }

    /// Waits until the open terminal has stayed the same for a second and `accept` takes it, then returns
    /// it; a second outlasts the keyboard's move and the layout after it. Fails with the last report when
    /// that never happens.
    @MainActor
    private func typing(_ probe: XCUIElement, _ point: String, until accept: (Typing) -> Bool) -> Typing? {
        let deadline = Date.now.addingTimeInterval(20)
        var steady: (since: Double, typing: Typing)?
        while Date.now < deadline {
            if let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
               let t = (object["t"] as? NSNumber)?.doubleValue,
               let grid = (object["grids"] as? [[String: Any]])?.first,
               let keyboardHides = (object["keyboardHides"] as? NSNumber)?.intValue {
                let typing = Typing(
                    cols: (grid["cols"] as? NSNumber)?.intValue ?? 0,
                    rows: (grid["rows"] as? NSNumber)?.intValue ?? 0,
                    resizes: (grid["resizes"] as? NSNumber)?.intValue ?? 0,
                    focused: grid["focused"] as? Bool ?? false,
                    keyboard: (object["keyboard"] as? NSNumber)?.intValue,
                    keyboardHides: keyboardHides
                )
                if steady?.typing != typing { steady = (t, typing) }
                if let steady, t - steady.since >= 1, accept(typing) { return typing }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("\(point): the probe never settled; last \(steady?.typing.description ?? "nothing")")
        return steady?.typing
    }

    private func assertFits(_ grids: [Grid], _ point: String) {
        XCTAssertFalse(grids.isEmpty, "\(point): no terminal on screen")
        XCTAssertEqual(grids.filter { $0.fit != "ok" }, [], "\(point): a terminal does not fit its card")
    }

    /// With LHUN_SHOTS set (tools/fit.sh sets it), draws a box the size of the terminal with
    /// tools/ruler.sh, which captures the screen of the run's destination once the prompt is back, and
    /// holds still meanwhile. The shell it is typed into has no LHUN_DEST of its own (tools/dest.zsh).
    @MainActor
    private func photograph(_ app: XCUIApplication, _ terminal: XCUIElement, _ pose: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let prefix = environment["LHUN_SHOTS"] else { return }
        guard let tools = environment["LHUN_TOOLS"], !tools.isEmpty else {
            XCTFail("LHUN_TOOLS must name this checkout's tools folder when taking photographs")
            return
        }
        let helper = (tools as NSString).appendingPathComponent("ruler.sh").replacingOccurrences(of: "'", with: "'\\''")
        let dest = environment["LHUN_DEST"].flatMap { $0.isEmpty ? nil : "LHUN_DEST='\($0)' " } ?? ""
        terminal.tap()
        app.typeText("\(dest)'\(helper)' \(prefix)-\(pose).png\n")
        sleep(15)
    }
}
