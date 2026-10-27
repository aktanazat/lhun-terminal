import XCTest

/// The session tools/keys.sh makes on the Mac for these checks, with tmux's status line off: a zsh to type
/// into (a).
private enum Fixture {
    static func name(_ suffix: String) -> String { "lhun-test-keys-\(suffix)" }
}

/// Option as Meta, typed at zsh on the Mac. Each key's bytes are read from the probe; tmux's size and
/// color replies can land between keys, so each check looks for the key's bytes among what went out
/// after it. Caps Lock has no check here: the Caps Lock XCUITest presses never reaches the app.
final class KeysShots: XCTestCase {
    /// Option-B twice moves two words back, Option-F one word forward: "echo one two three" becomes
    /// "echo one XtwoY three".
    @MainActor
    func testOptionAsMeta() throws {
        let (app, probe) = launch([])
        try typing(app, "a")
        app.typeText("echo one two three")
        sleep(1)
        try press(app, probe, "b", [.option], expect: [0x1B, 0x62])
        try press(app, probe, "b", [.option], expect: [0x1B, 0x62])
        try press(app, probe, "X", expect: [0x58])
        try press(app, probe, "f", [.option], expect: [0x1B, 0x66])
        try press(app, probe, "Y", expect: [0x59])
        sleep(1)
        keep(self, "03-option-b-option-f")
        app.typeText("\n")
        sleep(2)
        keep(self, "04-option-ran")
        // Option-Shift-. is Meta->, zsh's end of history.
        try press(app, probe, ".", [.option, .shift], expect: [0x1B, 0x3E])
        try keysSeen(probe, "05-keys-option-on")
    }

    /// The palette's Option as Meta row turns it off, and Option types its own characters, the shifted
    /// ones too; the row turns it back on. Launched with it on, whatever an earlier run left behind.
    @MainActor
    func testOptionOffFromPalette() throws {
        let (app, probe) = launch(["-optionAsMeta", "YES"])
        try typing(app, "a")
        try setting(app, "option-meta", query: "option as meta", from: "on", shot: "06-palette-key-settings")
        try press(app, probe, "b", [.option], expect: Array("∫".utf8))
        try press(app, probe, "2", [.option, .shift], expect: Array("€".utf8))
        sleep(1)
        keep(self, "07-option-off")
        try keysSeen(probe, "08-keys-option-off")
        app.typeKey("u", modifierFlags: .control)
        try setting(app, "option-meta", query: "option as meta", from: "off", shot: "09-palette-option-off")
        try press(app, probe, "b", [.option], expect: [0x1B, 0x62])
        app.typeKey("u", modifierFlags: .control)
    }

    /// Taps a palette setting found by `query`, checking it was `from` ("on" or "off"), then gives the
    /// terminal the keyboard back, with a warm-up key.
    @MainActor
    private func setting(_ app: XCUIApplication, _ id: String, query: String, from: String, shot: String) throws {
        app.buttons["palette"].tap()
        app.typeText(query)
        let row = app.descendants(matching: .any)["palette.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no \(id) row")
        XCTAssertEqual(row.value as? String, from, "\(id) was not \(from)")
        keep(self, shot)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["palette.query"].firstMatch.waitForNonExistence(timeout: 5))
        app.textViews["terminal"].firstMatch.tap()
        sleep(1)
        app.typeKey("u", modifierFlags: .control)
    }

    /// Opens the session, gives its terminal the keyboard, and clears the prompt's line, which is also the
    /// warm-up key the first typed key needs.
    @MainActor
    private func typing(_ app: XCUIApplication, _ session: String) throws {
        try open(app, session)
        app.textViews["terminal"].firstMatch.tap()
        sleep(1)
        app.typeKey("u", modifierFlags: .control)
        sleep(1)
    }

    /// Presses one key with `flags` held and checks that `expect` went out after it.
    @MainActor
    private func press(
        _ app: XCUIApplication, _ probe: XCUIElement, _ key: String, _ flags: XCUIElement.KeyModifierFlags = [],
        expect: [UInt8]
    ) throws {
        let before = try sentCount(probe)
        app.typeKey(key, modifierFlags: flags)
        try waitUntil(5, "\(key.debugDescription) with \(flags.rawValue) never sent \(hex(expect)); sent \(hex((try? sent(probe, since: before)) ?? []))") {
            ((try? sent(probe, since: before)) ?? []).contains(expect)
        }
    }

    @MainActor
    private func sentCount(_ probe: XCUIElement) throws -> Int {
        try sample(probe)["sentCount"] as? Int ?? 0
    }

    /// What went out to the session since the probe had counted `before` bytes, as far as its last 256
    /// bytes reach.
    @MainActor
    private func sent(_ probe: XCUIElement, since before: Int) throws -> [UInt8] {
        let now = try sample(probe)
        let hexText = Array(now["sent"] as? String ?? "")
        let bytes = stride(from: 0, to: hexText.count - 1, by: 2).compactMap { UInt8(String(hexText[$0...$0 + 1]), radix: 16) }
        let count = (now["sentCount"] as? Int ?? 0) - before
        return Array(bytes.suffix(max(0, count)))
    }

    /// Keeps the keys the system delivered, as the probe saw them: key code, characters, characters
    /// without modifiers, modifier flags.
    @MainActor
    private func keysSeen(_ probe: XCUIElement, _ name: String) throws {
        let keys = try sample(probe)["keysSeen"] as? [String] ?? []
        let note = XCTAttachment(string: keys.joined(separator: "\n"))
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Shared

@MainActor
private func launch(_ arguments: [String]) -> (XCUIApplication, XCUIElement) {
    let app = XCUIApplication()
    // Pills along the top whatever layout the device keeps, so the sessions' pills are there to tap.
    app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"] + arguments
    app.launch()
    let probe = app.descendants(matching: .any)["probe"].firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
    return (app, probe)
}

@MainActor
private func pill(_ app: XCUIApplication, _ suffix: String) -> XCUIElement {
    app.descendants(matching: .any)["session.mac.\(Fixture.name(suffix))"].firstMatch
}

/// Opens a fixture session from the palette and waits until it attaches. Other builders' sessions can
/// push its pill out of the strip, where a tap misses.
@MainActor
private func open(_ app: XCUIApplication, _ suffix: String) throws {
    let session = pill(app, suffix)
    XCTAssertTrue(session.waitForExistence(timeout: 30), "\(Fixture.name(suffix)) never appeared")
    app.buttons["palette"].tap()
    app.typeText(Fixture.name(suffix))
    let row = app.descendants(matching: .any)["palette.open.mac.\(Fixture.name(suffix))"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no row for \(suffix)")
    row.tap()
    let terminal = app.textViews["terminal"].firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
    XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(suffix) never attached")
    try waitUntil(10, "\(suffix)'s pill never showed as open") { session.isSelected }
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

@MainActor
private func sample(_ probe: XCUIElement) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
}

/// The whole screen: with the iPad lying in landscape, the app's own screenshot keeps only a
/// portrait-sized corner of it.
@MainActor
private func keep(_ test: XCTestCase, _ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    test.add(shot)
}
