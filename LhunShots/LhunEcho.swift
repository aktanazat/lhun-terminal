import XCTest

/// What Lhûn does over a slow or broken link. tools/echo.sh runs the host's side in sessions it names to
/// the test (ECHO_SESSION, alone or with a part after it), on their host (ECHO_HOST, mac or server).
final class LhunEcho: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// tools/echo.sh ends Lhûn's own connection to a still screen ECHO_DROPS times. Each time, every frame
    /// drawn from the drop until 3 seconds after Lhûn is attached again shows the screen from before the
    /// drop, never a cleared or half redrawn one, and the screen ends as it was.
    @MainActor
    func testReconnectKeepsTheScreen() throws {
        try keepsTheScreen(launching: [])
    }

    /// The same when tmux's redraw stalls partway each time, as over a slow link: each attach's output from
    /// its 600th byte on, after tmux's clear and the start of its redraw and before the redraw's end,
    /// reaches Lhûn 2.2 seconds late.
    @MainActor
    func testStalledRedrawKeepsTheScreen() throws {
        try keepsTheScreen(launching: ["-stallAt", "600", "-stallFor", "2.2"])
    }

    @MainActor
    private func keepsTheScreen(launching arguments: [String]) throws {
        let fixture = try Fixture()
        let drops = try XCTUnwrap(fixture.number("ECHO_DROPS"), "ECHO_DROPS")
        let (_, probe, _) = try open(fixture, fixture.session(), launching: arguments)
        var reconnects: [[String: Any]] = []
        let deadline = Date.now.addingTimeInterval(Double(drops) * 30)
        while reconnects.count < drops, Date.now < deadline {
            sleep(1)
            reconnects = try sample(probe)["reconnects"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(reconnects.count, drops, "reconnects the probe saw through")
        for reconnect in reconnects {
            XCTAssertEqual(reconnect["matched"] as? Bool, true, "the screen came back as it was: \(reconnect)")
            XCTAssertEqual(reconnect["broken"] as? Int, 0, "frames drawn cleared or half redrawn: \(reconnect)")
        }
    }

    /// At the server's shell, whose echo takes 80 ms or more, typed keys show ahead of their echo once
    /// eight echoes ran slow, and every one drawn is then matched by its echo: none is taken away.
    @MainActor
    func testTypedKeysShowAheadOfTheEcho() throws {
        let fixture = try Fixture()
        let (keys, probe) = try tapping(at: fixture.session("shell"), fixture)
        let start = try prediction(probe)
        keys.type("echo the server echoes each key")
        try waitFor(probe, "typed keys to show", timeout: 20) { $0.on }
        keys.type(" and these show at once")
        sleep(3)
        let settled = try prediction(probe)
        XCTAssertEqual(settled.resizes, start.resizes, "the grid changed while keys were typed: \(settled)")
        XCTAssertGreaterThan(settled.shown, 0, "no typed key was drawn ahead of its echo: \(settled)")
        XCTAssertEqual(settled.confirmed, settled.shown, "keys drawn that their echo did not match: \(settled)")
        XCTAssertEqual(settled.showing, 0, "guesses left on screen: \(settled)")
    }

    /// At a prompt reading a password, where the host echoes nothing, typed keys are guessed but never
    /// drawn, slow as the link is.
    @MainActor
    func testPasswordKeysNeverShow() throws {
        let fixture = try Fixture()
        let (app, probe) = try typing(at: fixture.session("password"), fixture)
        app.typeText("echo warming up")
        try waitFor(probe, "typed keys to show", timeout: 20) { $0.on }
        app.typeText("; read -rsp 'password: ' pw; echo; echo \"read ${#pw} characters\"\r")
        sleep(2)
        let before = try prediction(probe)
        app.typeText("hunter2hunter2")
        sleep(3)
        let after = try prediction(probe)
        XCTAssertGreaterThan(after.guessed, before.guessed, "the password's keys were not even guessed: \(after)")
        XCTAssertEqual(after.shown, before.shown, "password keys drawn: \(after)")
        app.typeText("\r")
    }

    /// In a full-screen program, here vim, on the alternate screen, no typed key is guessed: such a program
    /// puts typed keys where it likes, or nowhere.
    @MainActor
    func testFullScreenKeysAreNotGuessed() throws {
        let fixture = try Fixture()
        let (app, probe) = try typing(at: fixture.session("vim"), fixture)
        app.typeText("vim -u NONE -i NONE -N -n\r")
        let before = try waitFor(probe, "vim on the alternate screen", timeout: 15) { $0.alternateScreen }
        XCTAssertGreaterThan(before.guessed, 0, "the keys typed at the shell were not guessed either: \(before)")
        app.typeText("ityped into vim")
        sleep(2)
        let after = try prediction(probe)
        XCTAssertEqual(after.guessed, before.guessed, "keys typed into vim were guessed: \(after)")
        app.typeKey(".", modifierFlags: .command)
        app.typeText(":q!\r")
    }

    /// tools/echo.sh's program on the server echoes each key as it arrives, but for keys it never echoes,
    /// as at a password prompt, and letters it echoes in the other case, which no guess matches. Typed phase
    /// by phase (ECHO_PHASES): keys the echo matches show and settle; keys never echoed show, then all go
    /// at once when the timeout passes; a wrong echo takes every key showing away at once; and after Return
    /// and at the muted prompt, nothing shows. Keys are tapped about two a second, so the never-echoed keys
    /// typed after the timeout took the shown ones away are guessed without showing; the next phase waits
    /// until those have given up on their echo, or its own echo would settle them.
    @MainActor
    func testWrongGuessesGoAtOnce() throws {
        let fixture = try Fixture()
        let phases = try JSONDecoder().decode([Phase].self, from: Data(fixture.text("ECHO_PHASES").utf8))
        let (keys, probe) = try tapping(at: fixture.session("phases"), fixture)
        let start = try prediction(probe)
        var before = start
        for (number, phase) in phases.enumerated() {
            keys.type(phase.keys)
            // A guess off screen waits 10 s for its echo (EchoPrediction.patience).
            sleep(phase.echo == "muted" ? 11 : 3)
            let after = try prediction(probe)
            let shown = after.shown - before.shown, confirmed = after.confirmed - before.confirmed
            let erased = after.erased - before.erased, erasures = after.erasures - before.erasures
            let what = "phase \(number + 1), \(phase.keys.debugDescription): shown \(shown), confirmed \(confirmed), "
                + "erased \(erased) in \(erasures) goes, \(after.showing) still on screen"
            switch phase.expect {
            case "confirmed":
                XCTAssertGreaterThan(shown, 0, what)
                XCTAssertEqual(confirmed, shown, what)
            case "erased":
                XCTAssertGreaterThan(shown, 0, what)
                XCTAssertEqual(erased, shown, what)
                XCTAssertEqual(erasures, 1, what)
            default:
                XCTAssertEqual(shown, 0, what)
            }
            XCTAssertEqual(after.showing, 0, what)
            XCTAssertEqual(after.resizes, start.resizes, "the grid changed while keys were typed: \(what)")
            before = after
        }
    }

    /// tools/echo.sh's program on the server echoes each key 8 seconds late. Typed once that delay is
    /// known, keys show at once, underlined, and tools/echo.sh photographs them the moment the last one
    /// reaches the host; then each one drawn is matched by its echo.
    @MainActor
    func testTypedKeysShowWhileTheEchoIsAway() throws {
        let fixture = try Fixture()
        let (keys, probe) = try tapping(at: fixture.session("photo"), fixture)
        let start = try prediction(probe)
        keys.type(try fixture.text("ECHO_WARMUP"))
        try waitFor(probe, "typed keys to show", timeout: 60) { $0.on }
        let photographed = try fixture.text("ECHO_PHOTOGRAPHED")
        keys.type(photographed)
        try waitFor(probe, "every key typed on screen ahead of its echo", timeout: 5) { $0.showing == photographed.count }
        sleep(12)
        let settled = try prediction(probe)
        XCTAssertEqual(settled.resizes, start.resizes, "the grid changed while keys were typed: \(settled)")
        XCTAssertEqual(settled.showing, 0, "guesses left on screen: \(settled)")
        XCTAssertEqual(settled.confirmed, settled.shown, "keys drawn that their echo did not match: \(settled)")
    }

    /// At this Mac's shell, whose echo comes back within a frame or two, typed keys are guessed but never
    /// drawn: nothing on screen changes.
    @MainActor
    func testFastEchoShowsNothing() throws {
        let fixture = try Fixture()
        let (app, probe) = try typing(at: fixture.session("shell"), fixture)
        app.typeText("echo this mac echoes each key in time")
        sleep(3)
        let typed = try prediction(probe)
        XCTAssertGreaterThan(typed.guessed, 0, "the keys were not even guessed: \(typed)")
        XCTAssertFalse(typed.on, "typed keys show ahead of their echo: \(typed)")
        XCTAssertEqual(typed.shown, 0, "typed keys drawn ahead of their echo: \(typed)")
    }

    /// In a program that hides the terminal's cursor and draws its own, as omp does, no typed key is
    /// guessed: where its keys land is up to it.
    @MainActor
    func testHiddenCursorKeysAreNotGuessed() throws {
        let fixture = try Fixture()
        let (app, probe) = try typing(at: fixture.session("omp"), fixture)
        app.typeText(try fixture.text("ECHO_OMP") + "\r")
        try waitFor(probe, "omp to hide the cursor", timeout: 60) { !$0.cursorShown }
        sleep(3)
        let before = try prediction(probe)
        XCTAssertGreaterThan(before.guessed, 0, "the keys typed at the shell were not guessed either: \(before)")
        app.typeText("typed into omp")
        sleep(2)
        let after = try prediction(probe)
        XCTAssertFalse(after.cursorShown, "omp showed the cursor again: \(after)")
        XCTAssertEqual(after.guessed, before.guessed, "keys typed into omp were guessed: \(after)")
    }

    /// The steps behind a blank screen seen on the iPad: with the keyboard up, open a session running omp,
    /// put the keyboard down, and once it has attached, tap it to type. omp showed whole with the keyboard
    /// down, and nothing once it came back. tools/echo.sh runs omp in three sessions on this Mac: one this
    /// iPad sizes, one another screen sizes, each opened here held sideways and upright, and one whose
    /// connection it ends once, 5 seconds after Lhûn attaches. Each time the keyboard is back, the terminal
    /// shows, fits the card left above the keyboard, and shows omp's input line, where the cursor sits,
    /// with its output above.
    @MainActor
    func testOmpStaysInSightAsTheKeyboardComesBack() throws {
        // Each pass stands alone; one failing says nothing about the next.
        continueAfterFailure = true
        let original = XCUIDevice.shared.orientation
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = original }
        }
        let fixture = try Fixture()
        let shell = fixture.session("shell")
        let (app, probe, terminal) = try open(fixture, shell)
        terminal.tap()
        XCTAssertTrue(OnScreenKeyboard(app).up(within: 10), "the keyboard never came up at the shell")
        for (part, orientation) in [("own", UIDeviceOrientation.landscapeLeft), ("watched", .landscapeLeft), ("own", .portrait), ("watched", .portrait)] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            let what = "\(part), \(orientation == .portrait ? "upright" : "sideways")"
            try tapToType(fixture.session(part), after: shell, fixture, app, probe, what)
            // Closed, the card lets go of the session, so the next pass attaches anew.
            app.buttons["card.close"].firstMatch.tap()
            sleep(1)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let dropped = fixture.session("dropped")
        try tapToType(dropped, after: shell, fixture, app, probe, "dropped") {
            let deadline = Date.now.addingTimeInterval(40)
            while (try? sample(probe)["reconnects"] as? [[String: Any]])?.isEmpty ?? true, Date.now < deadline {
                sleep(1)
            }
            XCTAssertFalse((try sample(probe)["reconnects"] as? [[String: Any]])?.isEmpty ?? true, "\(dropped) never dropped and came back")
        }
    }

    /// From the shell with the keyboard up, opens `session`, puts the keyboard down, waits for the session
    /// to attach and for `meanwhile`, then taps the terminal to type and checks what shows once the
    /// keyboard has come to rest.
    @MainActor
    private func tapToType(
        _ session: String, after shell: String, _ fixture: Fixture, _ app: XCUIApplication, _ probe: XCUIElement,
        _ what: String, meanwhile: () throws -> Void = {}
    ) throws {
        let keyboard = OnScreenKeyboard(app)
        onStrip(app, shell).tap()
        if !keyboard.up(within: 3) {
            app.textViews["terminal"].firstMatch.tap()
            XCTAssertTrue(keyboard.up(within: 10), "\(what): the keyboard never came up at the shell")
        }
        sleep(1)
        onStrip(app, session).tap()
        keyboard.putDown(ifUpWithin: 5)
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(what): \(session) never attached")
        try meanwhile()
        sleep(2)
        shoot(app, "\(what), keyboard down")
        app.textViews["terminal"].firstMatch.tap()
        XCTAssertTrue(keyboard.up(within: 10), "\(what): the keyboard never came back")
        settledKeyboard(probe)
        sleep(2)
        shoot(app, "\(what), keyboard back")
        let grids = try sample(probe)["grids"] as? [[String: Any]] ?? []
        guard let grid = grids.first(where: { $0["session"] as? String == session }) else {
            return XCTFail("\(what): \(session) shows no terminal: \(grids)")
        }
        XCTAssertEqual(grid["focused"] as? Bool, true, "\(what): the terminal never took the keys: \(grid)")
        XCTAssertEqual(grid["seen"] as? Bool, true, "\(what): the terminal is hidden: \(grid)")
        XCTAssertEqual(grid["fit"] as? String, "ok", "\(what): the grid does not fit the card: \(grid)")
        XCTAssertEqual(grid["cursorText"] as? Bool, true, "\(what): omp's input line shows nothing: \(grid)")
        XCTAssertGreaterThanOrEqual(grid["textRows"] as? Int ?? 0, 3, "\(what): little of omp shows: \(grid)")
    }

    /// Keeps a picture of the screen with the result.
    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Launches Lhûn with the probe on, on the fixture's host, and opens a session there.
    @MainActor
    private func open(
        _ fixture: Fixture, _ session: String, launching arguments: [String] = []
    ) throws -> (app: XCUIApplication, probe: XCUIElement, terminal: XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", fixture.host, "-probe", "YES"] + arguments
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let pill = app.descendants(matching: .any)["session.\(fixture.host).\(session)"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(session) never appeared")
        pill.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "\(session) never showed a terminal")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(session) never attached")
        return (app, probe, terminal)
    }

    /// Opens a session, and gives its terminal the keys.
    @MainActor
    private func typing(at session: String, _ fixture: Fixture) throws -> (app: XCUIApplication, probe: XCUIElement) {
        let (app, probe, terminal) = try open(fixture, session)
        terminal.tap()
        // The first key XCTest sends after launch can go missing; Shift alone sends the host nothing.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sleep(1)
        return (app, probe)
    }

    /// Opens a session, gives its terminal the keys, and waits for the on-screen keyboard to come to rest, for
    /// keys tapped on it (OnScreenKeys).
    @MainActor
    private func tapping(at session: String, _ fixture: Fixture) throws -> (keys: OnScreenKeys, probe: XCUIElement) {
        let (app, probe, terminal) = try open(fixture, session)
        terminal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "\(session) never brought up the on-screen keyboard")
        settledKeyboard(probe)
        return (try OnScreenKeys(app), probe)
    }

    /// Waits for the on-screen keyboard to hold still for a second, by where the probe last saw its top.
    @MainActor
    private func settledKeyboard(_ probe: XCUIElement) {
        let deadline = Date.now.addingTimeInterval(20)
        var last = (top: try? sample(probe)["keyboard"] as? NSNumber, since: Date.now)
        while Date.now < deadline {
            let top = try? sample(probe)["keyboard"] as? NSNumber
            if top != last.top {
                last = (top, .now)
            } else if Date.now.timeIntervalSince(last.since) >= 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the keyboard never held still; its top was last at \(last.top?.description ?? "nothing")")
    }

    /// The probe's latest line.
    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
    }

    /// The open session's local echo, from the probe's latest line.
    @MainActor
    private func prediction(_ probe: XCUIElement) throws -> Prediction {
        try XCTUnwrap(Prediction(sample(probe)), "the probe reports no local echo: \(probe.label)")
    }

    /// Waits up to `timeout` seconds for the open session's local echo to reach a state, and returns it.
    @MainActor
    @discardableResult
    private func waitFor(
        _ probe: XCUIElement, _ what: String, timeout: TimeInterval, _ reached: (Prediction) -> Bool
    ) throws -> Prediction {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = try prediction(probe)
        while !reached(last), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            last = try prediction(probe)
        }
        XCTAssertTrue(reached(last), "waited \(Int(timeout)) s for \(what): \(last)")
        return last
    }
}

/// The open session's local echo as the probe reports it (Lhun/Probe.swift), and how often its grid changed.
private struct Prediction: CustomStringConvertible {
    let guessed, shown, confirmed, erased, erasures, showing, resizes: Int
    let on, alternateScreen, cursorShown: Bool

    init?(_ sample: [String: Any]) {
        guard let fields = sample["prediction"] as? [String: Any],
              let guessed = fields["guessed"] as? Int, let shown = fields["shown"] as? Int,
              let confirmed = fields["confirmed"] as? Int, let erased = fields["erased"] as? Int,
              let erasures = fields["erasures"] as? Int, let showing = fields["showing"] as? Int,
              let on = fields["on"] as? Bool, let alternateScreen = fields["alternateScreen"] as? Bool,
              let cursorShown = fields["cursorShown"] as? Bool,
              let grid = (sample["grids"] as? [[String: Any]])?.first(where: { $0["focused"] as? Bool == true }),
              let resizes = grid["resizes"] as? Int
        else { return nil }
        (self.guessed, self.shown, self.confirmed, self.erased, self.erasures, self.showing, self.resizes) =
            (guessed, shown, confirmed, erased, erasures, showing, resizes)
        (self.on, self.alternateScreen, self.cursorShown) = (on, alternateScreen, cursorShown)
    }

    var description: String {
        "guessed \(guessed), shown \(shown), confirmed \(confirmed), erased \(erased) in \(erasures) goes, "
            + "\(showing) on screen, on \(on), alternate screen \(alternateScreen), cursor shown \(cursorShown), "
            + "grid resized \(resizes) times"
    }
}

/// Types by tapping keys on the on-screen keyboard, where they lay when this was made. On a device,
/// XCUITest's typeText plugs in a pretend hardware keyboard for each burst, so the on-screen keyboard and
/// the key row go and come back, the terminal's grid changes with them, and local echo drops every guess
/// on screen when the grid changes, as it should. Taps leave the keyboard and the grid where they are.
/// Only the letters plane's keys, space and Return: all the tests tap.
@MainActor
struct OnScreenKeys {
    private let app: XCUIApplication
    private let centers: [Character: CGPoint]
    private let names: [String]

    init(_ app: XCUIApplication) throws {
        self.app = app
        var centers: [Character: CGPoint] = [:]
        var names: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            if element.elementType == .key || element.elementType == .button {
                let name = element.label.isEmpty ? element.identifier : element.label
                let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
                names.append(name)
                switch name.lowercased() {
                case "space": centers[" "] = center
                case "return": centers["\r"] = center
                default: if name.count == 1, let key = name.first { centers[key] = center }
                }
            }
            element.children.forEach(visit)
        }
        visit(try app.keyboards.firstMatch.snapshot())
        (self.centers, self.names) = (centers, names)
    }

    func type(_ keys: String) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for key in keys {
            guard let center = centers[key] else {
                return XCTFail("no on-screen key types \(String(key).debugDescription); the keyboard has \(names)")
            }
            origin.withOffset(CGVector(dx: center.x, dy: center.y)).tap()
        }
    }
}

/// Keys tools/echo.sh has testWrongGuessesGoAtOnce type, how the host echoes them, and what it expects of
/// the guesses among them.
private struct Phase: Decodable {
    let keys: String
    let echo: String
    let expect: String
}

/// The sessions tools/echo.sh made for the test, and how it set the run up.
private struct Fixture {
    let environment = ProcessInfo.processInfo.environment
    let host: String
    private let name: String

    init() throws {
        name = try XCTUnwrap(environment["ECHO_SESSION"], "run this test through tools/echo.sh")
        host = environment["ECHO_HOST"] ?? "mac"
    }

    /// The session tools/echo.sh named, or the one it made beside it for a part of its check.
    func session(_ part: String? = nil) -> String {
        part.map { "\(name)-\($0)" } ?? name
    }

    func number(_ name: String) -> Int? {
        environment[name].flatMap { Int($0) }
    }

    func text(_ name: String) throws -> String {
        try XCTUnwrap(environment[name], "\(name), from tools/echo.sh")
    }
}
