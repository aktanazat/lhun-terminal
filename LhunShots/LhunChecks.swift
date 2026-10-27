import UIKit
import XCTest

/// Checks on a real device what the arrow keys, the keyboard shortcuts, the command palette, a program's
/// copy and a tap on a web address do.
/// tools/checks.sh runs them all in one go against three sessions it makes on the Mac, lhun-test-checks-1
/// to -3, and kills every lhun-test-checks-* session afterwards, the ones the checks start included. The
/// app's probe reports the session it has open, the size of its text and what it copies.
/// Return and Esc from XCUITest's hardware keys never reach the app while the on-screen keyboard shows, so
/// commands go in as typed text and the palette closes with ⌘K or a tap.
final class LhunChecks: XCTestCase {
    private static let fixtures = ["lhun-test-checks-1", "lhun-test-checks-2", "lhun-test-checks-3"]
    /// The text size ⌘0 goes back to on an iPad.
    private static let defaultFontSize = 15
    /// Which way Lhûn's interface stands, as UIInterfaceOrientation's raw value, from the probe at launch.
    private var interfaceOrientation = 0

    override func setUp() {
        continueAfterFailure = false
    }

    /// The arrow keys send the bytes a terminal sends for them, never their names: the probe shows what
    /// each arrow put on the SSH channel, and the shell reads them as arrows, in normal and in application
    /// cursor mode. The shell starts a session named after the bytes it read, in hex, which the strip lists.
    @MainActor
    func testArrowKeys() throws {
        let (app, probe) = launch()
        open(app, probe, Self.fixtures[0]).tap()
        let keys: [XCUIKeyboardKey] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
        for (mode, setting, introducer) in [("normal", "l", "5b"), ("application", "h", "4f")] {
            let name = "lhun-test-checks-keys-\(mode)-"
            app.typeText(
                #"printf '\e[?1"# + setting + #"'; read -rk12 k; printf '\e[?1l'; "#
                    + #"tmux new-session -d -s "# + name + #"$(printf %s "$k" | xxd -p)"# + "\n"
            )
            sleep(1)
            var sent: [String] = []
            for key in keys {
                let before = channel(probe)
                app.typeKey(key.rawValue, modifierFlags: [])
                sleep(2)
                sent.append(bytes(written: channel(probe), since: before))
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "arrows in \(mode) cursor mode"
            shot.lifetime = .keepAlways
            add(shot)

            // tmux sets Lhûn's own cursor mode, so either form of the arrows is right, as long as it holds.
            let cursor = sent.first?.hasPrefix("1b4f") == true ? "4f" : "5b"
            let finals = ["44", "43", "41", "42"]
            XCTAssertEqual(sent, finals.map { "1b\(cursor)\($0)" }, "the bytes ← → ↑ ↓ each put on the channel, in hex")
            let pill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.mac.\(name)")).firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 15), "in \(mode) cursor mode the shell never read 12 bytes from ← → ↑ ↓")
            let read = finals.map { "1b\(introducer)\($0)" }.joined()
            XCTAssertEqual(pill.identifier, "session.mac.\(name)\(read)", "in \(mode) cursor mode the shell read other bytes (hex after the name)")
        }
    }

    /// ⌘ and a digit open the session at that place in the strip, tried on the checks' own three wherever
    /// they sit, so no one else's session is opened, and ⌘⇧[ and ⌘⇧] step to the one before and after;
    /// ⌘0, ⌘= and ⌘- set the text size; ⌘T starts a new session and opens it, and ⌘W ends it on the Mac.
    @MainActor
    func testShortcuts() throws {
        let (app, probe) = launch()
        warmUpKeyboard(app)
        let pills = Self.fixtures.map { "session.mac.\($0)" }
        for pill in pills {
            let place = try XCTUnwrap(sessionPills(app).firstIndex(of: pill), "\(pill) left the strip") + 1
            XCTAssertLessThanOrEqual(place, 9, "\(pill) sits past ⌘9 in the strip")
            app.typeKey("\(place)", modifierFlags: .command)
            assertSelection(probe, pill, after: "⌘\(place)")
        }
        app.typeKey("[", modifierFlags: [.command, .shift])
        assertSelection(probe, pills[1], after: "⌘⇧[")
        app.typeKey("]", modifierFlags: [.command, .shift])
        assertSelection(probe, pills[2], after: "⌘⇧]")

        open(app, probe, Self.fixtures[0])
        let size = try XCTUnwrap(fontSize(probe), "the probe never reported the text size")
        for (key, expected) in [("0", Self.defaultFontSize), ("=", Self.defaultFontSize + 1), ("-", Self.defaultFontSize),
                                ("-", Self.defaultFontSize - 1), ("0", Self.defaultFontSize)] {
            app.typeKey(key, modifierFlags: .command)
            assertFontSize(probe, expected, after: "⌘\(key)")
        }
        while let now = fontSize(probe), now != size {
            app.typeKey(now < size ? "=" : "-", modifierFlags: .command)
            assertFontSize(probe, now < size ? now + 1 : now - 1, after: "putting the text size back")
        }

        let strip = sessionPills(app)
        app.typeKey("t", modifierFlags: .command)
        let created = try XCTUnwrap(newSelection(probe, notIn: strip), "⌘T opened no new session")
        assertAttached(app, probe, created, after: "⌘T")

        app.typeKey("w", modifierFlags: .command)
        assertSelection(probe, nil, after: "⌘W")
        XCTAssertTrue(app.buttons[created].waitForNonExistence(timeout: 15), "⌘W left \(created) running on the Mac")
    }

    /// ⌘K opens the palette and closes it again, typing narrows it to what matches, and its New Session,
    /// Rename Session…, Detach and Kill Session… work on the open session.
    @MainActor
    func testPalette() throws {
        let (app, probe) = launch()
        warmUpKeyboard(app)
        let query = app.textFields["palette.query"]
        let first = app.buttons["palette.open.mac.\(Self.fixtures[0])"]
        let second = app.buttons["palette.open.mac.\(Self.fixtures[1])"]
        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette")
        // Only the rows in sight are drawn, and the Mac's other sessions can list above the fixtures, so
        // their shared name narrows the list first. New Session is found by name further on.
        query.typeText("lhun-test-checks-")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "the palette never listed \(Self.fixtures[0])")
        XCTAssertTrue(second.exists, "the palette never listed \(Self.fixtures[1])")
        keep("01-palette")
        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "⌘K left the palette open")

        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette again")
        query.typeText(Self.fixtures[1])
        XCTAssertTrue(first.waitForNonExistence(timeout: 10), "typing \(Self.fixtures[1]) left \(Self.fixtures[0]) listed")
        XCTAssertFalse(app.buttons["palette.new"].exists, "typing \(Self.fixtures[1]) left New Session listed")
        XCTAssertTrue(second.exists, "typing \(Self.fixtures[1]) hid \(Self.fixtures[1]) itself")
        keep("02-palette-narrowed")
        second.tap()
        assertAttached(app, probe, "session.mac.\(Self.fixtures[1])", after: "the palette's \(Self.fixtures[1])")

        let strip = sessionPills(app)
        try runCommand(app, probe, "new session", "new")
        let created = try XCTUnwrap(newSelection(probe, notIn: strip), "New Session opened no new session")
        assertAttached(app, probe, created, after: "New Session")

        let renamed = "lhun-test-checks-renamed"
        try runCommand(app, probe, "rename", "rename")
        let alert = app.alerts["Rename Session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Rename Session… never asked for a name")
        let field = alert.textFields.firstMatch
        // No tap on the field: it has the keyboard already, a tap opens the edit menu over the buttons,
        // and typeText fails on its own when the field lacks the keyboard.
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + renamed)
        XCTAssertEqual(field.value as? String, renamed, "the name typed into Rename Session…")
        let rename = alert.buttons["Rename"]
        settle(rename)
        rename.tap()
        assertSelection(probe, "session.mac.\(renamed)", after: "Rename Session…")
        XCTAssertTrue(app.buttons["session.mac.\(renamed)"].waitForExistence(timeout: 15), "the strip never showed \(renamed)")
        XCTAssertTrue(app.buttons[created].waitForNonExistence(timeout: 15), "the strip kept the old name \(created)")

        try runCommand(app, probe, "detach", "detach")
        assertSelection(probe, nil, after: "Detach")
        XCTAssertTrue(app.buttons["session.mac.\(renamed)"].exists, "Detach ended \(renamed) instead of leaving it running")

        open(app, probe, renamed)
        try killOpenSession(app, probe, "session.mac.\(renamed)")
    }

    /// A program's OSC 52 copy, made inside tmux, lands on the device's clipboard.
    @MainActor
    func testCopy() throws {
        let (app, probe) = launch()
        open(app, probe, Self.fixtures[1]).tap()
        let text = "lhun-test-checks-copy-\(UInt32.random(in: 0...UInt32.max))"
        let before = copied(probe)
        app.typeText(#"printf '\e]52;c;%s\a' "$(printf %s "# + text + #" | base64)""# + "\n")
        assertCopied(text, probe: probe, since: before, after: "the OSC 52 copy")
    }

    /// A tap opens a web address behind an OSC 8 link or written out in the text, from inside tmux: one on
    /// the session's own host in Lhûn's preview, the others in Safari.
    @MainActor
    func testLinks() throws {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["LHUN_CHECKS_PORT"], "the port tools/checks.sh serves a page on")
        let (app, probe) = launch()
        let screen = open(app, probe, Self.fixtures[2])
        screen.tap()
        app.typeText(
            #"clear; printf '\e]8;;https://example.com/\e\\lhun-osc8-link\e]8;;\e\\\n'; echo https://example.org/; "#
                + "echo http://localhost:\(port)/\n"
        )
        waitForQuiet(probe)
        let cell = try XCTUnwrap(probeGrids(probe)?.grids.first?.cell, "the probe never reported the terminal's cells")
        XCTAssertEqual(cell.count, 2, "the probe's cell size")
        keep("03-links")

        tap(screen, col: 8, row: 2, cell: cell)
        let preview = app.descendants(matching: .any)["preview.address"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "tapping the localhost address never opened the preview")
        let deadline = Date.now.addingTimeInterval(30)
        while !preview.label.contains("Lhun checks page"), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(preview.label.contains("Lhun checks page"), "the preview never showed the Mac's page: \(preview.label)")
        keep("04-link-localhost-in-preview")
        app.buttons["preview.close"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10), "the preview never closed")

        tap(screen, col: 4, row: 0, cell: cell)
        assertOpensInSafari("example.com", after: "tapping the OSC 8 link", shot: "05-link-osc8-in-safari")
        returnToLhun(app, probe, "session.mac.\(Self.fixtures[2])")
        tap(screen, col: 8, row: 1, cell: cell)
        assertOpensInSafari("example.org", after: "tapping the written-out address", shot: "06-link-written-in-safari")
        returnToLhun(app, probe, "session.mac.\(Self.fixtures[2])")
    }

    @MainActor
    private func launch() -> (app: XCUIApplication, probe: XCUIElement) {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the sessions' pills are there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        for fixture in Self.fixtures {
            XCTAssertTrue(
                app.buttons["session.mac.\(fixture)"].waitForExistence(timeout: 30),
                "\(fixture) never showed in the strip; tools/checks.sh makes it"
            )
        }
        interfaceOrientation = sample(probe)["orientation"] as? Int ?? 0
        return (app, probe)
    }

    /// XCUITest can lose the first hardware key after a launch. Esc with nothing open does nothing.
    @MainActor
    private func warmUpKeyboard(_ app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    @MainActor
    private func terminal(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["terminal"].firstMatch
    }

    /// Opens one of the checks' own sessions with its pill and returns its terminal.
    @MainActor
    @discardableResult
    private func open(_ app: XCUIApplication, _ probe: XCUIElement, _ name: String) -> XCUIElement {
        app.buttons["session.mac.\(name)"].tap()
        assertAttached(app, probe, "session.mac.\(name)", after: "tapping \(name)")
        return terminal(app)
    }

    /// The Mac's sessions in the strip, in order, as their pills' identifiers.
    @MainActor
    private func sessionPills(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.mac.")).allElementsBoundByIndex.map(\.identifier)
    }

    /// The probe's latest sample.
    @MainActor
    private func sample(_ probe: XCUIElement) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]) ?? [:]
    }

    /// The session the app has open, as its pill's identifier, from the probe; nil while none is.
    @MainActor
    private func selection(_ probe: XCUIElement) -> String? {
        guard let open = sample(probe)["selection"] as? [String: String], let host = open["host"], let name = open["name"]
        else { return nil }
        return "session.\(host).\(name)"
    }

    /// Waits until the app has `pill`'s session open, or none for nil.
    @MainActor
    private func assertSelection(_ probe: XCUIElement, _ pill: String?, after action: String) {
        let deadline = Date.now.addingTimeInterval(15)
        while selection(probe) != pill, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(selection(probe), pill, "the session open after \(action)")
    }

    /// Waits for the app to open a session that is not one of `known`, and returns its pill's identifier.
    @MainActor
    private func newSelection(_ probe: XCUIElement, notIn known: [String]) -> String? {
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if let open = selection(probe), !known.contains(open) { return open }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    /// The app has `pill`'s session open, marks its pill, and shows its terminal attached.
    @MainActor
    private func assertAttached(_ app: XCUIApplication, _ probe: XCUIElement, _ pill: String, after action: String) {
        assertSelection(probe, pill, after: action)
        XCTAssertTrue(app.buttons[pill].wait(for: \.isSelected, toEqual: true, timeout: 15), "\(action) did not mark \(pill) open")
        XCTAssertTrue(terminal(app).waitForExistence(timeout: 15), "\(action) showed no terminal")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(action): \(pill) never attached")
    }

    /// Runs a palette command: ⌘K, the query, then a tap on the row; the palette closes after it.
    @MainActor
    private func runCommand(_ app: XCUIApplication, _ probe: XCUIElement, _ query: String, _ id: String) throws {
        let field = app.textFields["palette.query"]
        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "⌘K never opened the palette")
        field.typeText(query)
        let row = app.buttons["palette.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the palette never listed \(id) for \"\(query)\"")
        row.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "the palette stayed open after \(id)")
    }

    /// Kills the open session with the palette's Kill Session… and its confirmation.
    @MainActor
    private func killOpenSession(_ app: XCUIApplication, _ probe: XCUIElement, _ pill: String) throws {
        try runCommand(app, probe, "kill", "kill")
        let kill = app.buttons["Kill Session"]
        XCTAssertTrue(kill.waitForExistence(timeout: 10), "Kill Session… never asked to confirm")
        kill.tap()
        assertSelection(probe, nil, after: "Kill Session")
        XCTAssertTrue(app.buttons[pill].waitForNonExistence(timeout: 15), "Kill Session left \(pill) in the strip")
    }

    /// The text size of the terminal on screen, from the probe.
    @MainActor
    private func fontSize(_ probe: XCUIElement) -> Int? {
        probeGrids(probe)?.grids.first?.font
    }

    @MainActor
    private func assertFontSize(_ probe: XCUIElement, _ size: Int, after action: String) {
        let deadline = Date.now.addingTimeInterval(10)
        while fontSize(probe) != size, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(fontSize(probe), size, "the text size after \(action)")
    }

    /// Waits until `element` has held still for a second and a half. XCUITest types through a hardware
    /// keyboard it plugs in for the purpose, so the on-screen keyboard leaves while it types and comes back
    /// after, and an alert moves with it both times: a tap in between lands where the button was.
    @MainActor
    private func settle(_ element: XCUIElement) {
        var frame = element.frame
        var since = Date.now
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let now = element.frame
            if now != frame {
                frame = now
                since = Date.now
            } else if Date.now.timeIntervalSince(since) >= 1.5 {
                return
            }
        }
        XCTFail("\(element.label) was still moving after 10 seconds")
    }

    /// Waits until no output has reached the terminals for two of the probe's samples in a row, a second
    /// apart.
    @MainActor
    private func waitForQuiet(_ probe: XCUIElement) {
        var last = sample(probe)["bytesFed"] as? Int
        var quiet = 0
        let deadline = Date.now.addingTimeInterval(20)
        while quiet < 2, Date.now < deadline {
            Thread.sleep(forTimeInterval: 1)
            let fed = sample(probe)["bytesFed"] as? Int
            quiet = fed == last ? quiet + 1 : 0
            last = fed
        }
    }

    /// Taps the middle of a cell of the terminal on screen.
    @MainActor
    private func tap(_ screen: XCUIElement, col: Int, row: Int, cell: [Double]) {
        let offset = CGVector(dx: (Double(col) + 0.5) * cell[0], dy: (Double(row) + 0.5) * cell[1])
        screen.coordinate(withNormalizedOffset: .zero).withOffset(offset).tap()
    }

    /// Safari comes to the front on an address at `host`. The screenshot is kept once the page shows,
    /// and the tab closes again.
    @MainActor
    private func assertOpensInSafari(_ host: String, after action: String, shot: String) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "\(action) never brought Safari forward")
        let deadline = Date.now.addingTimeInterval(20)
        var shown = safari.debugDescription.contains(host)
        while !shown, Date.now < deadline {
            Thread.sleep(forTimeInterval: 1)
            shown = safari.debugDescription.contains(host)
        }
        if !shown { keep(safari.debugDescription, "safari after \(action)") }
        XCTAssertTrue(shown, "\(action) brought Safari forward, but not on \(host)")
        _ = safari.staticTexts["Example Domain"].waitForExistence(timeout: 15)
        keep(shot)
        safari.typeKey("w", modifierFlags: .command)
    }

    /// Brings Lhûn back from Safari and waits for its session to be attached again.
    @MainActor
    private func returnToLhun(_ app: XCUIApplication, _ probe: XCUIElement, _ pill: String) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Lhûn never came back from Safari")
        assertAttached(app, probe, pill, after: "coming back from Safari")
    }

    /// Keeps a screenshot of the whole screen in the result; tools/checks.sh copies out the numbered ones.
    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image))
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// XCTest takes the screen as the panel lies, in portrait, while Lhûn stands in landscape; this turns
    /// the picture the way the interface stands, as the probe reported at launch.
    @MainActor
    private func upright(_ screen: UIImage) -> UIImage {
        let turn: UIImage.Orientation
        switch UIInterfaceOrientation(rawValue: interfaceOrientation) {
        case .landscapeRight: turn = .left
        case .landscapeLeft: turn = .right
        default: return screen
        }
        guard screen.size.width < screen.size.height, let pixels = screen.cgImage else { return screen }
        let turned = UIImage(cgImage: pixels, scale: screen.scale, orientation: turn)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in turned.draw(at: .zero) }
    }

    @MainActor
    private func keep(_ text: String, _ name: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }

    /// The bytes Lhûn has written to the SSH channels, from the probe's latest sample: how many, and the
    /// last of them.
    @MainActor
    private func channel(_ probe: XCUIElement) -> (count: Int, last: [UInt8]) {
        let latest = sample(probe)
        let hex = Array((latest["sent"] as? String ?? "").utf8)
        let last = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
            UInt8(String(decoding: hex[$0...$0 + 1], as: UTF8.self), radix: 16)
        }
        return (latest["sentCount"] as? Int ?? 0, last)
    }

    /// The bytes written between two looks at the channel, in hex, leaving out the terminal's answers to
    /// tmux asking its size (CSI … t) and colors (OSC 10 and 11), which come whenever the on-screen
    /// keyboard shows or hides.
    private func bytes(written after: (count: Int, last: [UInt8]), since before: (count: Int, last: [UInt8])) -> String {
        let written = String(decoding: after.last.suffix(max(0, after.count - before.count)), as: UTF8.self)
        let keys = written.replacing(/\u{1B}\[[0-9;]*t|\u{1B}\][^\u{1B}\u{07}]*(\u{1B}\\|\u{07})/, with: "")
        return Array(keys.utf8).map { String(format: "%02x", $0) }.joined()
    }
}
