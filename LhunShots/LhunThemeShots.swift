import XCTest

/// Themes on a device (tools/themes.sh): the theme picker tries each theme across the app as its highlight
/// reaches it, a tap off the list puts the saved one back and Return keeps it, through a relaunch too; each
/// appearance keeps its own pick; the Mac's Ghostty theme comes from its config; the appearance rows hold
/// whatever the iPad shows; and each host has its own look. tools/themes.sh makes <THEMES_PREFIX>-a on the
/// Mac and <THEMES_PREFIX>-h on the server, both showing tools/visible-pattern.sh, writes a Ghostty config
/// on the Mac naming Rose Pine Dawn and Rose Pine (THEMES_GHOSTTY), and photographs the screen whenever a
/// test holds still for it. Each test starts from Mies, Match iPad and each host's usual look, whatever is
/// saved, and saves those again through the palette when it ends, pass or fail, then puts the device's
/// appearance back.
final class LhunThemeShots: XCTestCase {
    /// Launch arguments read like saved choices, so a launch with these starts from them.
    private static let usual = [
        "-themeLight", "mies", "-themeDark", "mies", "-appearance", "match",
        "-hostTheme.mac.light", "lhun", "-hostTheme.mac.dark", "lhun",
        "-hostTheme.server.light", "tinted", "-hostTheme.server.dark", "tinted",
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    /// A tap off the list puts back what the highlight tried, Return keeps it through a relaunch, and the
    /// light and dark appearances each keep their own pick.
    @MainActor
    func testPickerTriesKeepsAndPutsBack() throws {
        let a = try fixture("a")
        begin(.dark)
        var (app, probe) = launch(Self.usual)
        open(app, "mac", a)
        expect(probe, "dark Mies") { $0.style == "dark" && $0.shown == "Mies" && $0.backgrounds == ["0E0E0E"] }

        let query = picker(app, "theme")
        XCTAssertEqual(app.buttons["themes.mies"].value as? String, "current", "the picker should check Mies")
        query.typeText("indigo")
        expect(probe, "trying Indigo Hour") {
            $0.preview == "Indigo Hour" && $0.shown == "Indigo Hour" && $0.backgrounds == ["181729"] && $0.dark == "mies"
        }
        keep("picker-dark")
        // XCUITest's Esc never reaches the app while the on-screen keyboard shows, as on a simulator; a tap
        // off the list closes the picker the way Esc does.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.35)).tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "a tap off the list left the picker open")
        expect(probe, "a tap off the list putting Mies back") {
            $0.preview.isEmpty && $0.shown == "Mies" && $0.backgrounds == ["0E0E0E"]
        }

        let again = picker(app, "theme")
        again.typeText("ember")
        expect(probe, "trying Ember Study") { $0.preview == "Ember Study" }
        again.typeText("\n")
        XCTAssertTrue(again.waitForNonExistence(timeout: 10), "Return left the picker open")
        expect(probe, "keeping Ember Study") { $0.dark == "ember-study" && $0.preview.isEmpty && $0.backgrounds == ["1E150E"] }

        app.terminate()
        (app, probe) = launch()
        open(app, "mac", a)
        expect(probe, "Ember Study after a relaunch") {
            $0.dark == "ember-study" && $0.shown == "Ember Study" && $0.backgrounds == ["1E150E"]
        }
        keep("kept-dark")

        XCUIDevice.shared.appearance = .light
        expect(probe, "light still on Mies") { $0.style == "light" && $0.shown == "Mies" && $0.backgrounds == ["F8F8F7"] }
        let light = picker(app, "theme")
        light.typeText("celadon")
        expect(probe, "trying Celadon Day") { $0.preview == "Celadon Day" && $0.backgrounds == ["ECF8F0"] }
        keep("picker-light")
        light.typeText("\n")
        XCTAssertTrue(light.waitForNonExistence(timeout: 10), "Return left the picker open")
        expect(probe, "keeping Celadon Day for light only") {
            $0.light == "celadon-day" && $0.dark == "ember-study" && $0.backgrounds == ["ECF8F0"]
        }
        keep("kept-light")
        XCUIDevice.shared.appearance = .dark
        expect(probe, "dark still on Ember Study") {
            $0.style == "dark" && $0.shown == "Ember Study" && $0.backgrounds == ["1E150E"]
        }
    }

    /// The picker offers the Mac's Ghostty theme for each appearance, read from its config when the picker
    /// opens, and keeps it like any other.
    @MainActor
    func testMacGhosttyTheme() throws {
        let a = try fixture("a")
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["THEMES_GHOSTTY"], "run this test through tools/themes.sh")
        begin(.dark)
        let (app, probe) = launch(Self.usual + ["-ghosttyConfig", config])
        open(app, "mac", a)

        let query = picker(app, "theme")
        ghosttyRow(app, shows: "Rose Pine")
        query.typeText("ghostty")
        expect(probe, "trying Rose Pine") { $0.preview == "Rose Pine" && $0.shown == "Rose Pine" && $0.backgrounds == ["191724"] }
        keep("ghostty-dark")
        query.typeText("\n")
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "Return left the picker open")
        expect(probe, "keeping Rose Pine") { $0.dark == "ghostty" && $0.ghostty.last == "Rose Pine" && $0.backgrounds == ["191724"] }

        XCUIDevice.shared.appearance = .light
        expect(probe, "light still on Mies") { $0.style == "light" && $0.shown == "Mies" }
        let light = picker(app, "theme")
        ghosttyRow(app, shows: "Rose Pine Dawn")
        light.typeText("ghostty")
        expect(probe, "trying Rose Pine Dawn") { $0.preview == "Rose Pine Dawn" && $0.backgrounds == ["FAF4ED"] }
        keep("ghostty-light")
        light.typeText("\n")
        XCTAssertTrue(light.waitForNonExistence(timeout: 10), "Return left the picker open")
        expect(probe, "keeping Rose Pine Dawn") { $0.light == "ghostty" && $0.ghostty == ["Rose Pine Dawn", "Rose Pine"] }
    }

    /// Appearance: Dark and Appearance: Light hold whatever the iPad shows, and Match iPad follows it again.
    @MainActor
    func testAppearanceRows() throws {
        let a = try fixture("a")
        begin(.light)
        let (app, probe) = launch(Self.usual)
        open(app, "mac", a)
        expect(probe, "light, as the iPad is") { $0.appearance == "match" && $0.style == "light" && $0.backgrounds == ["F8F8F7"] }
        run(app, "appearance dark", row: "appearance.dark")
        expect(probe, "dark on a light iPad") { $0.appearance == "dark" && $0.style == "dark" && $0.backgrounds == ["0E0E0E"] }
        keep("appearance-dark")
        XCUIDevice.shared.appearance = .dark
        run(app, "appearance light", row: "appearance.light")
        expect(probe, "light on a dark iPad") { $0.appearance == "light" && $0.style == "light" && $0.backgrounds == ["F8F8F7"] }
        keep("appearance-light")
        run(app, "appearance match", row: "appearance.match")
        expect(probe, "dark again with the iPad") { $0.appearance == "match" && $0.style == "dark" && $0.backgrounds == ["0E0E0E"] }
    }

    /// The server's wash and pills take a tint from one of the theme's colors and the Mac's do not, and a
    /// host can take a theme of its own while the other keeps its look.
    @MainActor
    func testEachHostLooksItsOwn() throws {
        let (a, h) = (try fixture("a"), try fixture("h"))
        begin(.dark)
        let (app, probe) = launch(Self.usual)
        open(app, "mac", a)
        let mac = expect(probe, "the Mac in plain Mies") { $0.host == "mac" && $0.shown == "Mies" && $0.pill == "D6D6D6" }
        keep("host-mac-dark")

        run(app, "switch to server", row: "host.server")
        open(app, "server", h)
        // The session switched away from stays attached off screen, so the probe lists its terminal too, in
        // the colors it last showed: it takes the current ones when it shows again.
        let server = expect(probe, "the server tinted toward dark Mies's cyan") {
            $0.host == "server" && $0.shown == "Mies" && $0.pill == "83A3A3" && Set($0.backgrounds) == ["0E0E0E"]
        }
        XCTAssertNotEqual(server.wash, mac.wash, "the server's wash should take its tint")
        keep("host-server-dark")
        XCUIDevice.shared.appearance = .light
        expect(probe, "the server tinted toward light Mies's cyan") {
            $0.style == "light" && $0.host == "server" && $0.pill == "4D7676" && $0.backgrounds.contains("F8F8F7")
        }
        keep("host-server-light")

        run(app, "switch to mac", row: "host.mac")
        open(app, "mac", a)
        expect(probe, "the Mac back, now in light Mies") { $0.host == "mac" && Set($0.backgrounds) == ["F8F8F7"] }
        let query = picker(app, "theme.mac")
        query.typeText("rice")
        // The server's terminal, when it stays attached, keeps light Mies.
        expect(probe, "trying Rice Paper on the Mac") {
            $0.preview == "Rice Paper" && $0.host == "mac"
                && $0.backgrounds.sorted() == ($0.backgrounds.count == 2 ? ["F8F8F7", "FAF7F1"] : ["FAF7F1"])
        }
        keep("host-mac-theme-light")
        query.typeText("\n")
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "Return left the picker open")
        expect(probe, "the Mac keeping Rice Paper for light, the server as it was") {
            $0.looks["mac"] == "theme:rice-paper lhun" && $0.looks["server"] == "tinted tinted" && $0.light == "mies"
                && $0.shown == "Rice Paper"
                && $0.backgrounds.sorted() == ($0.backgrounds.count == 2 ? ["F8F8F7", "FAF7F1"] : ["FAF7F1"])
        }
    }

    // MARK: Steps

    /// Sets the device's appearance for the test. When the test ends, pass or fail, the usual choices are
    /// saved again, then the device's appearance goes back: two blocks, so a failure in the first still
    /// runs the second.
    @MainActor
    private func begin(_ appearance: XCUIDevice.Appearance) {
        let original = XCUIDevice.shared.appearance
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = original }
        addTeardownBlock { @MainActor in self.putBack() }
        XCUIDevice.shared.appearance = appearance
    }

    /// Saves Mies in both appearances, Match iPad and each host's usual look again through the palette, as
    /// he would choose them, from a launch that reads what the test saved.
    @MainActor
    private func putBack() {
        let (app, probe) = launch()
        if Shown(probe).appearance != "match" { run(app, "appearance match", row: "appearance.match") }
        for dark in [true, false] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let now = expect(probe, "the iPad's appearance") { $0.appearance == "match" && $0.style == (dark ? "dark" : "light") }
            if now.chosen(dark: dark) != "mies" { choose(app, "theme", row: "mies") }
            for (host, usual) in [("mac", "lhun"), ("server", "tinted")] where now.look(of: host, dark: dark) != usual {
                choose(app, "theme.\(host)", row: usual)
            }
        }
        expect(probe, "the usual choices saved") {
            $0.light == "mies" && $0.dark == "mies" && $0.appearance == "match"
                && $0.looks == ["mac": "lhun lhun", "server": "tinted tinted"]
        }
        app.terminate()
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> (app: XCUIApplication, probe: XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"] + arguments
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        // XCUITest's first key after a launch can go astray; this one types nothing.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        return (app, probe)
    }

    /// Opens a session with its pill on the strip and waits for it to attach, then lowers the keyboard when
    /// it is up, so the screen shows the terminal.
    @MainActor
    private func open(_ app: XCUIApplication, _ host: String, _ name: String) {
        let pill = app.descendants(matching: .any)["session.\(host).\(name)"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(name) never appeared on the \(host) strip")
        pill.tap()
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        let hide = app.buttons["Hide Keyboard"].firstMatch
        if hide.waitForExistence(timeout: 3) { hide.tap() }
    }

    /// Finds a palette row by typing `text`, and taps it.
    @MainActor
    private func run(_ app: XCUIApplication, _ text: String, row id: String) {
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the palette never opened")
        query.typeText(text)
        let row = app.buttons["palette.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the palette has no \(id) row")
        row.tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "the palette stayed open")
    }

    /// Opens Theme… (`theme`) or a host's Theme for… (`theme.<host>`) from the palette, and returns its
    /// search field.
    @MainActor
    @discardableResult
    private func picker(_ app: XCUIApplication, _ command: String) -> XCUIElement {
        let host = command.split(separator: ".").dropFirst().first
        run(app, host.map { "theme for \($0)" } ?? "theme", row: command)
        let query = app.textFields["themes.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the theme picker never opened")
        return query
    }

    /// Keeps a picker row by tapping it.
    @MainActor
    private func choose(_ app: XCUIApplication, _ command: String, row id: String) {
        picker(app, command)
        let row = app.buttons["themes.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the picker has no \(id) row")
        row.tap()
        XCTAssertTrue(app.textFields["themes.query"].waitForNonExistence(timeout: 10), "the picker stayed open")
    }

    /// Waits for the picker's Ghostty row to name the theme it read from the Mac.
    @MainActor
    private func ghosttyRow(_ app: XCUIApplication, shows name: String) {
        let row = app.buttons["themes.ghostty"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the picker has no Ghostty row")
        let deadline = Date.now.addingTimeInterval(20)
        while row.value as? String != name, Date.now < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertEqual(row.value as? String, name, "the Ghostty row")
    }

    /// Waits up to 15 seconds for the probe to show what `holds` accepts, and returns what it showed.
    @MainActor
    @discardableResult
    private func expect(_ probe: XCUIElement, _ what: String, _ holds: (Shown) -> Bool) -> Shown {
        let deadline = Date.now.addingTimeInterval(15)
        var shown = Shown(probe)
        while !holds(shown), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            shown = Shown(probe)
        }
        XCTAssertTrue(holds(shown), "\(what): the probe shows \(shown)")
        return shown
    }

    /// Has tools/themes.sh photograph the device's screen as `name`.png, and holds still until it has. The
    /// test asks with an empty file in its own Documents, take-themes-<name>, and tools/themes.sh answers
    /// with taken-themes-<name> once devicectl has saved the picture, which stands the way the iPad is held.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-themes-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-themes-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the screenshot \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/themes.sh never photographed \(name)")
    }

    private func fixture(_ suffix: String) throws -> String {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["THEMES_PREFIX"], "run this test through tools/themes.sh")
        return "\(prefix)-\(suffix)"
    }
}

/// The probe's theme report: what is chosen, what shows for the strip's host in the appearance on screen,
/// and each terminal's background.
private struct Shown: CustomStringConvertible {
    let appearance, style, light, dark, preview, host, shown, pill: String
    /// The strip host's wash, one flat color.
    let wash: String
    /// Each host's saved look, light then dark: `lhun`, `tinted` or `theme:<id>`.
    let looks: [String: String]
    let ghostty, backgrounds: [String]

    @MainActor
    init(_ probe: XCUIElement) {
        let sample = (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8))) as? [String: Any] ?? [:]
        let theme = sample["theme"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String { theme[key] as? String ?? "" }
        appearance = text("appearance")
        style = text("style")
        light = text("light")
        dark = text("dark")
        preview = text("preview")
        host = text("host")
        shown = text("shown")
        pill = text("pill")
        looks = theme["looks"] as? [String: String] ?? [:]
        wash = text("wash")
        ghostty = theme["ghostty"] as? [String] ?? []
        backgrounds = sample["backgrounds"] as? [String] ?? []
    }

    func chosen(dark: Bool) -> String {
        dark ? self.dark : light
    }

    func look(of host: String, dark: Bool) -> String {
        let pair = (looks[host] ?? "").split(separator: " ")
        return pair.count == 2 ? String(pair[dark ? 1 : 0]) : ""
    }

    var description: String {
        "appearance \(appearance), \(style), light \(light), dark \(dark), trying '\(preview)', \(host) showing \(shown) "
            + "with wash \(wash) and pills \(pill), looks \(looks), Ghostty \(ghostty), backgrounds \(backgrounds)"
    }
}
