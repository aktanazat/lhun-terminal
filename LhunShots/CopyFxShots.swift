import XCTest

/// The sessions tools/copyfx.sh makes on the Mac for these checks, with tmux's status line off: a (the
/// live terminal), h (300 rows of one word, to read back through), s (a screen to copy whole) and k1
/// to k3 (to kill).
private enum Fixture {
    static func name(_ suffix: String) -> String { "lhun-test-copyfx-\(suffix)" }
}

/// A copy flashes what it copied and a kill fades the card away. Most cases run the effects 20 times
/// slower (the probe's -effectsPace), so tools/copyfx.sh can photograph each one halfway through
/// devicectl, which takes a second or two; two run them at their own speed, with XCTest's own
/// screenshots taken as fast as it can after each. Every copy is checked by the size and SHA-256 the
/// probe reports, every effect has to let go of its layers (the probe's `effects` back to 0), and the
/// real-speed cases count the frames Lhûn draws in the 10 seconds after: none.
final class CopyFxShots: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A long press on the live terminal and Copy flash the word; so does a double tap and Copy, which is
    /// the terminal's own selection rather than the screen laid over it.
    @MainActor
    func test1FlashOnTheLiveTerminal() throws {
        let (app, probe) = launch(pace: 20)
        let terminal = try open(app, probe, "a")
        let cell = try cellSize(probe)
        run("clear; echo alpha bravo charlie", app, probe)
        var before = copied(probe)
        at(8, 0, cell, on: terminal).press(forDuration: 1.2)
        let selection = app.textViews["selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the long press laid nothing over the terminal")
        tapCopy(app, "the long-pressed word")
        try effectRuns(probe, "the flash on the long-pressed word")
        keep("01-flash-live")
        assertCopied("bravo", probe: probe, since: before, after: "Copy on the long-pressed word")
        try effectsEnd(probe)
        at(30, 8, cell, on: selection).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5), "a tap away left the word selected")

        before = copied(probe)
        at(15, 0, cell, on: terminal).doubleTap()
        tapCopy(app, "the double-tapped word")
        try effectRuns(probe, "the flash on the double-tapped word")
        keep("02-flash-live-double-tap")
        assertCopied("charlie", probe: probe, since: before, after: "Copy on the double-tapped word")
        try effectsEnd(probe)
    }

    /// Swiped back into history, a long press on a word and Copy flash it.
    @MainActor
    func test2FlashInHistory() throws {
        let (app, probe) = launch(pace: 20)
        let terminal = try open(app, probe, "h")
        let cell = try cellSize(probe)
        let history = app.textViews["history"]
        terminal.swipeDown(velocity: .fast)
        XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
        // History reads older rows in after it opens; a press while the rows move selects across them.
        _ = try settled(probe) { $0["history"] as? [String: Any] }
        sleep(1)
        let before = copied(probe)
        history.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: cell.width * 2.5, dy: history.frame.height * 0.6)).press(forDuration: 1.2)
        tapCopy(app, "the long-pressed word in history")
        try effectRuns(probe, "the flash in history")
        keep("03-flash-history")
        assertCopied("copyfxword", probe: probe, since: before, after: "Copy on a word in history")
        try effectsEnd(probe)
    }

    /// The palette's Copy Screen flashes the whole card. tools/copyfx.sh checks the copy against the
    /// screen tmux holds.
    @MainActor
    func test3FlashTheWholeCard() throws {
        let (app, probe) = launch(pace: 20)
        _ = try open(app, probe, "s")
        run("clear; echo the screen copied whole", app, probe)
        let before = copied(probe)
        try palette(app, "copy screen", row: "copy-screen")
        try effectRuns(probe, "the card's flash")
        keep("04-flash-screen")
        let copy = try XCTUnwrap(nextCopy(probe, since: before), "Copy Screen put nothing on the clipboard")
        XCTContext.runActivity(named: "screen \(copy)") { _ in }
        try effectsEnd(probe)
    }

    /// With Copy on Select on from the palette, a long press copies the word with no Copy tapped, and so
    /// does a double tap. Turned off again at the end, as it was.
    @MainActor
    func test4CopyOnSelect() throws {
        let (app, probe) = launch(pace: 20)
        let terminal = try open(app, probe, "a")
        let cell = try cellSize(probe)
        try setting(app, "copy-on-select", from: "off", shot: "05-copy-on-select-row")
        run("clear; echo alpha bravo charlie", app, probe)
        var before = copied(probe)
        at(8, 0, cell, on: terminal).press(forDuration: 1.2)
        try effectRuns(probe, "the flash when the long press lifted")
        keep("06-copy-on-select-live")
        assertCopied("bravo", probe: probe, since: before, after: "a long press with Copy on Select")
        try effectsEnd(probe)
        let selection = app.textViews["selection"]
        at(30, 8, cell, on: selection).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5), "a tap away left the word selected")

        before = copied(probe)
        at(15, 0, cell, on: terminal).doubleTap()
        try effectRuns(probe, "the flash after the double tap")
        assertCopied("charlie", probe: probe, since: before, after: "a double tap with Copy on Select")
        try effectsEnd(probe)
        at(30, 8, cell, on: terminal).tap()
        try setting(app, "copy-on-select", from: "on", shot: nil)
    }

    /// Kill Session from the palette fades k1's card away, and k2 is still there. tools/copyfx.sh checks
    /// tmux on the Mac: k1 gone, k2 left.
    @MainActor
    func test5FadeOnKill() throws {
        let (app, probe) = launch(pace: 20)
        _ = try open(app, probe, "k2")
        _ = try open(app, probe, "k1")
        sleep(2)
        try kill(app)
        try effectRuns(probe, "the fade")
        // The fade takes 5 s at this pace; with devicectl's second or two, the picture lands near its middle.
        sleep(1)
        keep("07-fade")
        try effectsEnd(probe)
        XCTAssertTrue(pill(app, "k1").waitForNonExistence(timeout: 15), "k1's pill stayed after the kill")
        XCTAssertTrue(pill(app, "k2").exists, "k2's pill went with k1's")
    }

    /// At its own speed, a copy's flash is over and gone within a second, and Lhûn draws nothing after.
    @MainActor
    func test6FlashAtItsSpeed() throws {
        let (app, probe) = launch(pace: 1)
        let terminal = try open(app, probe, "a")
        let cell = try cellSize(probe)
        run("clear; echo alpha bravo charlie", app, probe)
        let before = copied(probe)
        at(8, 0, cell, on: terminal).press(forDuration: 1.2)
        let selection = app.textViews["selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the long press laid nothing over the terminal")
        tapCopy(app, "the long-pressed word", wait: false)
        burst("08-flash-real")
        assertCopied("bravo", probe: probe, since: before, after: "Copy on the long-pressed word")
        try effectsEnd(probe, within: 3)
        at(30, 8, cell, on: selection).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5), "a tap away left the word selected")
        measureFrames(app)
    }

    /// At its own speed, a kill's fade is over and gone within a second, and Lhûn draws nothing after.
    @MainActor
    func test7FadeAtItsSpeed() throws {
        let (app, probe) = launch(pace: 1)
        _ = try open(app, probe, "k3")
        sleep(2)
        try kill(app)
        burst("09-fade-real")
        try effectsEnd(probe, within: 3)
        XCTAssertTrue(pill(app, "k3").waitForNonExistence(timeout: 15), "k3's pill stayed after the kill")
        measureFrames(app)
    }

    /// With Reduce Motion on in the iPad's Settings, the flash is a plain fade. Reduce Motion goes back off
    /// at the end, also when the case fails.
    @MainActor
    func test8PlainFlashWithReduceMotion() throws {
        try Self.setReduceMotion(true)
        addTeardownBlock { @MainActor in try CopyFxShots.setReduceMotion(false) }
        let (app, probe) = launch(pace: 20)
        let terminal = try open(app, probe, "a")
        let cell = try cellSize(probe)
        run("clear; echo alpha bravo charlie", app, probe)
        let before = copied(probe)
        at(15, 0, cell, on: terminal).doubleTap()
        tapCopy(app, "the double-tapped word")
        try effectRuns(probe, "the fade on the copied word")
        keep("10-reduce-motion-flash")
        assertCopied("charlie", probe: probe, since: before, after: "Copy with Reduce Motion on")
        try effectsEnd(probe)
    }

    // MARK: Steps

    @MainActor
    private func launch(pace: Int) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES",
        "-effectsPace", "\(pace)", "-copyOnSelect", "NO",]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        return (app, probe)
    }

    @MainActor
    private func pill(_ app: XCUIApplication, _ suffix: String) -> XCUIElement {
        app.descendants(matching: .any)["session.mac.\(Fixture.name(suffix))"].firstMatch
    }

    /// Opens a fixture session from the palette, attached, gives its terminal the keyboard with one key
    /// (XCUITest's first resizes the card) and waits for the grid to settle.
    @MainActor
    private func open(_ app: XCUIApplication, _ probe: XCUIElement, _ suffix: String) throws -> XCUIElement {
        XCTAssertTrue(pill(app, suffix).waitForExistence(timeout: 30), "\(Fixture.name(suffix)) never appeared")
        app.buttons["palette"].tap()
        app.typeText(Fixture.name(suffix))
        let row = app.descendants(matching: .any)["palette.open.mac.\(Fixture.name(suffix))"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no row for \(suffix)")
        row.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(suffix) never attached")
        try waitUntil(10, "\(suffix)'s pill never showed as open") { pill(app, suffix).isSelected }
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        _ = try settled(probe) { ($0["grids"] as? [[String: Any]])?.first }
        return terminal
    }

    /// Runs a palette command found by `query`.
    @MainActor
    private func palette(_ app: XCUIApplication, _ query: String, row id: String) throws {
        app.buttons["palette"].tap()
        app.typeText(query)
        let row = app.descendants(matching: .any)["palette.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no \(id) row")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["palette.query"].firstMatch.waitForNonExistence(timeout: 5))
    }

    /// Taps a palette setting, checking it was `from`, with a screenshot of the row first when `shot` is
    /// given, then gives the terminal the keyboard back.
    @MainActor
    private func setting(_ app: XCUIApplication, _ id: String, from: String, shot: String?) throws {
        app.buttons["palette"].tap()
        app.typeText("copy on select")
        let row = app.descendants(matching: .any)["palette.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no \(id) row")
        XCTAssertEqual(row.value as? String, from, "\(id) was not \(from)")
        if let shot { keep(shot) }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["palette.query"].firstMatch.waitForNonExistence(timeout: 5))
        app.textViews["terminal"].firstMatch.tap()
        sleep(1)
    }

    /// Kills the open session from the palette, through its confirmation.
    @MainActor
    private func kill(_ app: XCUIApplication) throws {
        try palette(app, "kill session", row: "kill")
        let confirm = app.buttons["Kill Session"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no Kill Session in the confirmation")
        confirm.tap()
    }

    /// Taps Copy in the menu the selection shows; `wait` waits for the menu to go.
    @MainActor
    private func tapCopy(_ app: XCUIApplication, _ what: String, wait: Bool = true) {
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
        XCTAssertTrue(copy.firstMatch.waitForExistence(timeout: 5), "\(what): no Copy in the menu")
        let button = copy.allElementsBoundByIndex.first { $0.isHittable } ?? copy.firstMatch
        button.tap()
        if wait { XCTAssertTrue(button.waitForNonExistence(timeout: 5), "\(what): the menu stayed after Copy") }
    }

    /// The middle of a cell, `column` and `row` from the element's top left.
    @MainActor
    private func at(_ column: Double, _ row: Double, _ cell: CGSize, on element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (column + 0.5) * cell.width, dy: (row + 0.5) * cell.height))
    }

    /// Types a command line and Return, and waits for the shell's output to stop arriving.
    @MainActor
    private func run(_ command: String, _ app: XCUIApplication, _ probe: XCUIElement) {
        let before = number(probe, "bytesFed")
        app.typeText(command + "\n")
        let deadline = Date.now.addingTimeInterval(20)
        var last = (bytes: before, since: Date.now)
        while Date.now < deadline {
            let bytes = number(probe, "bytesFed")
            if bytes != last.bytes {
                last = (bytes, .now)
            } else if bytes > before, Date.now.timeIntervalSince(last.since) >= 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the shell's output to \(command.debugDescription) never stopped arriving")
    }

    /// Waits for the probe to show an effect running, which at the slowed pace lasts several seconds.
    @MainActor
    private func effectRuns(_ probe: XCUIElement, _ what: String) throws {
        try waitUntil(5, "\(what) never ran") { number(probe, "effects") > 0 }
    }

    /// Waits for the probe to show no effect running: each has ended and let go of its layers.
    @MainActor
    private func effectsEnd(_ probe: XCUIElement, within seconds: TimeInterval = 20) throws {
        let started = Date.now
        try waitUntil(seconds, "an effect was still running after \(Int(seconds)) s") { number(probe, "effects") == 0 }
        XCTContext.runActivity(named: String(format: "effects at 0 after %.1f s", Date.now.timeIntervalSince(started))) { _ in }
    }

    /// The next copy Lhûn makes after `before`, or nil when none comes within 15 seconds.
    @MainActor
    private func nextCopy(_ probe: XCUIElement, since before: ProbeCopy?) -> ProbeCopy? {
        let deadline = Date.now.addingTimeInterval(15)
        repeat {
            if let latest = copied(probe), latest.count > before?.count ?? 0 { return latest }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date.now < deadline
        return nil
    }

    // MARK: Probe

    @MainActor
    private func sample(_ probe: XCUIElement) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]) ?? [:]
    }

    @MainActor
    private func number(_ probe: XCUIElement, _ key: String) -> Int {
        (sample(probe)[key] as? NSNumber)?.intValue ?? -1
    }

    /// What `part` picks out of the probe's samples, once two samples in a row agree on it.
    @MainActor
    private func settled(_ probe: XCUIElement, _ part: ([String: Any]) -> [String: Any]?) throws -> [String: Any] {
        var previous: (t: Double, part: NSDictionary)?
        var settled: [String: Any] = [:]
        try waitUntil(20, "what the probe shows never held still") {
            let latest = sample(probe)
            guard let t = (latest["t"] as? NSNumber)?.doubleValue, t != previous?.t, let now = part(latest)
            else { return false }
            if let previous, previous.part.isEqual(to: now) {
                settled = now
                return true
            }
            previous = (t, now as NSDictionary)
            return false
        }
        return settled
    }

    /// One character cell of the terminal on screen, in points.
    @MainActor
    private func cellSize(_ probe: XCUIElement) throws -> CGSize {
        let grid = try settled(probe) { ($0["grids"] as? [[String: Any]])?.first }
        let cell = try XCTUnwrap(grid["cell"] as? [NSNumber], "the probe shows no cell size")
        XCTAssertEqual(cell.count, 2, "the probe's cell size")
        return CGSize(width: cell[0].doubleValue, height: cell[1].doubleValue)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ failure: @autoclosure () -> String, _ done: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !done() {
            guard Date.now < deadline else { throw Failure(errorDescription: failure()) }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Turns Reduce Motion on or off in the Settings app, under Accessibility, Motion.
    @MainActor
    private static func setReduceMotion(_ on: Bool) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for label in ["Accessibility", "Motion"] {
            let row = settings.staticTexts[label].firstMatch
            guard row.waitForExistence(timeout: 10) else {
                throw Failure(errorDescription: "Settings shows no \(label)")
            }
            row.tap()
        }
        let toggle = settings.switches["Reduce Motion"].firstMatch
        guard toggle.waitForExistence(timeout: 10) else {
            throw Failure(errorDescription: "Settings shows no Reduce Motion switch")
        }
        let wanted = on ? "1" : "0"
        if toggle.value as? String != wanted {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        }
        let deadline = Date.now.addingTimeInterval(5)
        while toggle.value as? String != wanted, Date.now < deadline { usleep(200_000) }
        guard toggle.value as? String == wanted else {
            throw Failure(errorDescription: "Reduce Motion stayed \(toggle.value ?? "unknown"), wanted \(wanted)")
        }
        settings.terminate()
    }

    // MARK: Frames and screenshots

    /// Has the probe mark a 10-second window for XCTest once things have settled. XCTest runs the block
    /// twice and reports the second.
    @MainActor
    private func measureFrames(_ app: XCUIApplication) {
        sleep(4)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        let window = XCTOSSignpostMetric(subsystem: "com.aktanazat.lhun", category: "probe", name: "frames")
        measure(metrics: [window, XCTHitchMetric(application: app)], options: options) {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.aktanazat.lhun.probe.frames" as CFString), nil, nil, true
            )
            sleep(12)
        }
    }

    /// `count` of XCTest's own screenshots, as fast as it takes them, each named with its time after the
    /// first. They come out on their side; tools/copyfx.sh turns them upright.
    @MainActor
    private func burst(_ name: String, count: Int = 4) {
        let start = Date.now
        let shots = (0..<count).map { _ in (XCUIScreen.main.screenshot(), Date.now.timeIntervalSince(start)) }
        for (index, (shot, time)) in shots.enumerated() {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = String(format: "%@-%d-%03dms", name, index + 1, Int(time * 1000))
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Has tools/copyfx.sh photograph the device's screen through devicectl as `name`.png, upright, and
    /// holds still until it has: the test asks with an empty file named for the shot in its Documents, and
    /// the script answers with another once the picture is saved. Both carry the copyfx prefix, since
    /// other checks share the runner's Documents.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-copyfx-\(name)").path(percentEncoded: false)
        let ask = documents.appending(path: "take-copyfx-\(name)").path(percentEncoded: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: ask, contents: nil), "could not ask for the screenshot \(name)")
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/copyfx.sh never photographed \(name)")
    }
}
