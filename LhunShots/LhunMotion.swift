import XCTest

/// How the terminals move while Lhûn does one thing, display frame by display frame, on a real iPad held
/// sideways and used by touch: the probe's motion trace (MotionTrace in the app). Each test launches Lhûn,
/// sets a scene up and has the app trace while it taps what a person taps. The taps land on points found
/// before the trace starts, so no query of the app's views runs on its main thread meanwhile; only the
/// history swipes go through their elements, as a coordinate drag never opened history. No key is typed
/// through XCTest: on a device that plugs in a pretend hardware keyboard and puts the on-screen one down.
///
/// What the eye reads as jitter fails a test: a terminal edge going one way and then back (a reversal),
/// one covering most of its travel in a single frame (a snap), a terminal taking more grids on the way than
/// the move needs, each one redrawn by tmux, a terminal that sets off or comes to rest apart from the
/// keyboard it moves with, and the keyboard going away and coming back between two terminals. Frames the
/// main thread missed are logged, not judged: they depend on the device's load. tools/motion.sh runs the
/// tests and prints every trace.
final class LhunMotion: XCTestCase {
    /// How long the probe traces once asked, as Probe.motionSeconds says.
    private static let traced: TimeInterval = 4

    /// With the keyboard down, + opens a new session in the card: the new terminal comes up with the
    /// keyboard in one move, set off and brought to rest with it, at the grid it keeps.
    @MainActor
    func testNewTabWithTheKeyboardDown() throws {
        let (app, probe) = launch("new tab, keyboard down")
        _ = newSession(app, probe)
        // The new session's terminal took the keyboard.
        OnScreenKeyboard(app).putDown(ifUpWithin: 5)
        sleep(2)
        let plus = spot(app.buttons["new-session"])
        let motion = try trace("new tab, keyboard down", probe) { plus.tap() }
        assertSmooth(motion, "a new tab with the keyboard down")
    }

    /// With the keyboard up, + opens a new session in the card: the keyboard stays, and the new terminal
    /// shows at the grid the old one had.
    @MainActor
    func testNewTabWithTheKeyboardUp() throws {
        let (app, probe) = launch("new tab, keyboard up")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let plus = spot(app.buttons["new-session"])
        let motion = try trace("new tab, keyboard up", probe) { plus.tap() }
        assertSmooth(motion, "a new tab with the keyboard up", keyboard: .stays)
    }

    /// Closing the only card takes its terminal and the keyboard away together.
    @MainActor
    func testClosingTheCard() throws {
        let (app, probe) = launch("close")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let close = spot(app.buttons["card.close"])
        let motion = try trace("close", probe) { close.tap() }
        assertSmooth(motion, "closing the card")
    }

    /// A tap on another session's pill puts that session in the card; the keyboard stays.
    @MainActor
    func testSwitchingSessions() throws {
        let (app, probe) = launch("switch")
        let first = newSession(app, probe)
        _ = newSession(app, probe, after: first)
        raiseKeyboard(app)
        let pill = spot(onStrip(app, first))
        let motion = try trace("switch", probe) { pill.tap() }
        XCTAssertEqual((label(probe)?["selection"] as? [String: Any])?["name"] as? String, first, "the intended session never opened")
        assertSmooth(motion, "switching to \(first)", keyboard: .stays)
    }

    /// Split Right opens a second card beside the first, which narrows once; closing the new card gives the
    /// first its width back, again with one grid. The keyboard stays throughout.
    @MainActor
    func testSplittingAndClosing() throws {
        let (app, probe) = launch("split")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let splitRight = spot(app.buttons["card.splitRight"])
        let split = try trace("split right", probe) { splitRight.tap() }
        assertSmooth(split, "splitting right", regrids: 1, keyboard: .stays)
        let close = spot(glyph("card.close", app, probe))
        let closed = try trace("close the split", probe) { close.tap() }
        assertSmooth(closed, "closing the new card", regrids: 1, keyboard: .stays)
    }

    /// With two cards side by side, a tap on the other card gives it the focus and the keyboard with no
    /// move; zooming the focused card and bringing both back each give each card that changes one grid.
    @MainActor
    func testFocusAndZoom() throws {
        let (app, probe) = launch("focus and zoom")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        app.buttons["card.splitRight"].tap()
        XCTAssertTrue(app.buttons["card.zoom"].firstMatch.waitForExistence(timeout: 30), "the split never opened")
        sleep(3)
        let left = spot(terminals(app).first)
        let focus = try trace("focus the other card", probe) { left.tap() }
        assertSmooth(focus, "focusing the other card", keyboard: .stays)
        let zoom = spot(glyph("card.zoom", app, probe))
        let zoomed = try trace("zoom", probe) { zoom.tap() }
        assertSmooth(zoomed, "zooming the card", regrids: 1, keyboard: .stays)
        let restore = spot(glyph("card.zoom", app, probe))
        let restored = try trace("restore", probe) { restore.tap() }
        assertSmooth(restored, "bringing both cards back", regrids: 1, keyboard: .stays)
    }

    /// In the sidebar layout, the sidebar slides in and out, the card narrowing and widening once each way;
    /// all sessions' grid opens over the card and closes again without resizing it. The card slides on the
    /// grid's own spring as the keyboard steps aside and back, so it need not keep time with the keyboard.
    @MainActor
    func testSidebarAndGrid() throws {
        let (app, probe) = launch("sidebar and grid", layout: ["-layout", "sidebar", "-sidebar", "NO"])
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let sidebar = spot(app.buttons["sidebar-toggle"])
        let shown = try trace("sidebar in", probe) { sidebar.tap() }
        assertSmooth(shown, "showing the sidebar", regrids: 1)
        sleep(1)
        let hidden = try trace("sidebar out", probe) { sidebar.tap() }
        assertSmooth(hidden, "hiding the sidebar", regrids: 1)
        sleep(1)
        let grid = spot(app.buttons["peek-toggle"])
        let opened = try trace("grid open", probe) { grid.tap() }
        assertSmooth(opened, "opening the grid", followsKeyboard: false)
        sleep(1)
        let closed = try trace("grid close", probe) { grid.tap() }
        assertSmooth(closed, "closing the grid", followsKeyboard: false)
    }

    /// A swipe down opens history over the terminal, swipes scroll it, and a key takes it away again. The
    /// session lists the Mac's disks twice first, so it has lines above the screen to read back.
    @MainActor
    func testHistory() throws {
        let (app, probe) = launch("history")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let keys = try OnScreenKeys(app)
        keys.type("tmux set mouse off\rdf\rdf\r")
        sleep(2)
        let terminal = try XCTUnwrap(terminals(app).first, "no terminal on screen")
        let history = app.textViews["history"]
        let opened = try trace("history open", probe) { terminal.swipeDown(velocity: .fast) }
        XCTAssertTrue(history.waitForExistence(timeout: 5), "history never opened")
        assertSmooth(opened, "opening history")
        let scrolled = try trace("history scroll", probe) { for _ in 0..<3 { history.swipeDown(velocity: .fast) } }
        assertSmooth(scrolled, "scrolling history", keyboard: .stays)
        let closed = try trace("history close", probe) { keys.type("e") }
        assertSmooth(closed, "a key closing history")
    }

    /// The keyboard goes down and comes back up, and the terminal's bottom follows it frame for frame,
    /// with one grid at each end.
    @MainActor
    func testKeyboard() throws {
        let (app, probe) = launch("keyboard")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let hide = spot(OnScreenKeyboard(app).hide)
        let down = try trace("keyboard down", probe) { hide.tap() }
        assertSmooth(down, "the keyboard going down", regrids: 1)
        sleep(1)
        let terminal = spot(terminals(app).first)
        let up = try trace("keyboard up", probe) { terminal.tap() }
        assertSmooth(up, "the keyboard coming up", regrids: 1)
    }

    /// Typing a line and running it moves nothing but the cursor.
    @MainActor
    func testTyping() throws {
        let (app, probe) = launch("typing")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let keys = try OnScreenKeys(app)
        let typed = try trace("typing", probe) { keys.type("echo smooth\r") }
        assertSmooth(typed, "typing", keyboard: .stays)
    }

    /// Turning the iPad upright and back reshapes the card once each way. One trace holds both turns: held
    /// still on a desk, the iPad turns itself back within a couple of seconds of being turned upright. So
    /// the card's foot goes down the screen and back up once, its one reversal. Turning, UIKit tells of the
    /// keyboard's moves as instant and carries it round with the window, then, turned back, slides it up
    /// from below: there is no timing of the keyboard's to keep pace with.
    @MainActor
    func testTurning() throws {
        let (app, probe) = launch("turning")
        _ = newSession(app, probe)
        raiseKeyboard(app)
        let turned = try trace("turn upright and back", probe) {
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        assertSmooth(turned, "turning upright and back", reversals: 1, regrids: 2, followsKeyboard: false)
    }

    // MARK: Scenes

    /// Launches Lhûn held sideways with the probe on, its launch line naming `run`, in the tabs layout
    /// unless `layout` says otherwise. When the test ends, Lhûn closes and the iPad turns back.
    @MainActor
    private func launch(_ run: String, layout: [String] = ["-layout", "tabs"]) -> (app: XCUIApplication, probe: XCUIElement) {
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
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-shares", "{}", "-probeRun", run]
            + layout
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        return (app, probe)
    }

    /// Opens a new session on the Mac with +, waits for it to attach and come to rest, and returns its name.
    @MainActor
    private func newSession(_ app: XCUIApplication, _ probe: XCUIElement, after previous: String? = nil) -> String {
        let plus = app.buttons["new-session"]
        XCTAssertTrue(plus.wait(for: \.isEnabled, toEqual: true, timeout: 30), "the + glyph never came on")
        plus.tap()
        var name = ""
        let deadline = Date.now.addingTimeInterval(30)
        repeat {
            let selection = (label(probe)?["selection"] as? [String: Any])?["name"] as? String ?? ""
            if !selection.isEmpty, selection != previous { name = selection }
            Thread.sleep(forTimeInterval: 0.3)
        } while name.isEmpty && Date.now < deadline
        XCTAssertFalse(name.isEmpty, "no new session opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        sleep(3)
        return name
    }

    /// Brings the on-screen keyboard up on the focused terminal and lets it and the card come to rest.
    @MainActor
    private func raiseKeyboard(_ app: XCUIApplication) {
        guard !OnScreenKeyboard(app).isUp else { return }
        terminals(app).last?.tap()
        XCTAssertTrue(OnScreenKeyboard(app).up(within: 10), "the on-screen keyboard never came up")
        sleep(2)
    }

    /// The terminals on screen, left to right.
    @MainActor
    private func terminals(_ app: XCUIApplication) -> [XCUIElement] {
        app.textViews.matching(identifier: "terminal").allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The middle of where `element` is now, to tap later without asking the app where it is.
    @MainActor
    private func spot(_ element: XCUIElement?) -> XCUICoordinate {
        let app = XCUIApplication()
        guard let element, element.waitForExistence(timeout: 10) else {
            XCTFail("nothing to tap")
            return app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }
        let frame = element.frame
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
    }

    /// One of the focused card's header glyphs, by identifier. Both cards' headers keep theirs in the
    /// tree, so the card is picked first, by the session the probe says has the focus.
    @MainActor
    private func glyph(_ identifier: String, _ app: XCUIApplication, _ probe: XCUIElement) -> XCUIElement {
        let name = (label(probe)?["selection"] as? [String: Any])?["name"] as? String ?? ""
        return app.descendants(matching: .any)["card.mac.\(name)"].firstMatch.buttons[identifier].firstMatch
    }

    // MARK: Traces

    /// Has the probe trace while `action` runs, from a few still frames before it, and returns the trace's
    /// summary, attached to the result under `what`.
    @MainActor
    private func trace(_ what: String, _ probe: XCUIElement, _ action: () -> Void) throws -> Motion {
        let before = try XCTUnwrap(label(probe)?["t"] as? Double, "the probe reports no time")
        let posted = Date.now
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.aktanazat.lhun.probe.motion" as CFString), nil, nil, true
        )
        Thread.sleep(forTimeInterval: 0.3)
        action()
        // Asking for the label meanwhile would run on the app's main thread, in the frames being traced.
        Thread.sleep(until: posted.addingTimeInterval(Self.traced + 0.5))
        let deadline = Date.now.addingTimeInterval(10)
        var summary: [String: Any]?
        while summary == nil, Date.now < deadline {
            if let object = label(probe), let t = object["t"] as? Double, t >= before + Self.traced {
                summary = object["lastMotion"] as? [String: Any]
            }
            if summary == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        let motion = Motion(summary: try XCTUnwrap(summary, "\(what): the probe never reported its trace"))
        let attachment = XCTAttachment(string: motion.description)
        attachment.name = what
        attachment.lifetime = .keepAlways
        add(attachment)
        return motion
    }

    @MainActor
    private func label(_ probe: XCUIElement) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
    }

    /// Whether the keyboard should hold still through a transition.
    private enum Keyboard {
        case stays
        case free
    }

    /// Fails on more reversals than `reversals` or any snap, on more grids after each terminal's first than
    /// `regrids` in all, on a terminal bottom that sets off or comes to rest more than a frame apart from
    /// the keyboard where the cards follow it, and on the keyboard moving where it should stay. That reads
    /// the key row riding on it, which is what shows: UIKit's account of a handover between two terminals
    /// (`keyboard`) can report a move it never makes.
    @MainActor
    private func assertSmooth(
        _ motion: Motion, _ what: String, reversals: Int = 0, regrids: Int = 0, keyboard: Keyboard = .free,
        followsKeyboard: Bool = true, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(motion.count("reversals"), reversals, "\(what): edges that went back. \(motion)", file: file, line: line)
        XCTAssertEqual(motion.count("snaps"), 0, "\(what): edges that jumped. \(motion)", file: file, line: line)
        XCTAssertLessThanOrEqual(motion.count("regrids"), regrids, "\(what): grids taken on the way. \(motion)", file: file, line: line)
        for (name, lag) in motion.lag where followsKeyboard && (abs(lag.start) > 1 || abs(lag.end) > 1) {
            XCTFail("\(what): \(name) set off \(lag.start) and stopped \(lag.end) frames after the keyboard. \(motion)", file: file, line: line)
        }
        if keyboard == .stays {
            XCTAssertNil(motion.moved["key row"], "\(what): the keyboard moved. \(motion)", file: file, line: line)
        }
    }
}

/// One trace's summary, as the probe reports it (`lastMotion`).
private struct Motion: CustomStringConvertible {
    let summary: [String: Any]

    func count(_ key: String) -> Int {
        (summary[key] as? NSNumber)?.intValue ?? 0
    }

    /// How each part moved, by part, where it moved at all.
    var moved: [String: Any] {
        summary["moved"] as? [String: Any] ?? [:]
    }

    /// Display frames from the keyboard's first and last step to each terminal bottom's.
    var lag: [String: (start: Int, end: Int)] {
        (summary["keyboardLag"] as? [String: [String: NSNumber]] ?? [:]).compactMapValues { entry in
            guard let start = entry["start"]?.intValue, let end = entry["end"]?.intValue else { return nil }
            return (start, end)
        }
    }

    var description: String {
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) else { return "\(summary)" }
        return String(decoding: data, as: UTF8.self)
    }
}
