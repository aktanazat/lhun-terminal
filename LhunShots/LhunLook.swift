import XCTest

/// The compact layout, the terminal's fonts, the palette's loose matching and Reduce Motion on a real
/// device. tools/look.sh makes a tmux session on the Mac for the run, <LOOK_PREFIX>-a: a zsh showing
/// numbered lines then a sample of letters, styles and Nerd Font icons. It photographs the screen whenever
/// a test holds still for it, and checks tmux was only ever sent sizes Lhûn held on screen.
final class LhunLook: XCTestCase {
    /// Compact Layout, from the palette's Settings, takes the wash from around and between two cards: they
    /// meet at the middle of the screen and reach both edges, and each terminal fits its wider card with
    /// more columns. Turning it off brings the gutters and the earlier grids back.
    @MainActor
    func testCompactLayoutPutsCardsEdgeToEdge() throws {
        let (app, probe) = launch()
        let a = try fixture("a")
        try open(app, a)
        addTeardownBlock { @MainActor in self.setCompactLayout(app, false) }
        setCompactLayout(app, false)
        app.typeKey("d", modifierFlags: .command)
        let split = settle(probe, "split right") { $0.count == 2 && $0.contains { $0.session == a } }
        let twin = try XCTUnwrap(split.first { $0.session != a }?.session, "no second card")
        hideKeyboard(app)
        let roomy = settle(probe, "two cards with gutters") { $0.count == 2 && focused($0) == nil }
        assertFits(roomy, "two cards with gutters")
        let width = app.windows.firstMatch.frame.width
        let (left, right) = (header(app, a), header(app, twin))
        XCTAssertEqual(right.frame.minX - left.frame.maxX, 8, accuracy: 1, "the gutter between the cards")
        keep("compact-before")

        setCompactLayout(app, true)
        hideKeyboard(app)
        let compact = settle(probe, "two cards edge to edge") {
            $0.count == 2 && focused($0) == nil && $0.allSatisfy { grid in grid.cols > cols(roomy, grid.session) }
        }
        assertFits(compact, "two cards edge to edge")
        XCTAssertEqual(left.frame.minX, 0, accuracy: 1, "the left card's edge")
        XCTAssertEqual(right.frame.minX, left.frame.maxX, accuracy: 1, "where the cards meet")
        XCTAssertEqual(right.frame.maxX, width, accuracy: 1, "the right card's edge")
        keep("compact")

        setCompactLayout(app, false)
        hideKeyboard(app)
        let back = settle(probe, "gutters again") { $0.count == 2 && focused($0) == nil }
        assertFits(back, "gutters again")
        XCTAssertEqual(back.map { "\($0.session) \($0.cols)x\($0.rows)" }.sorted(), roomy.map { "\($0.session) \($0.cols)x\($0.rows)" }.sorted(),
                       "the grids with gutters again")
    }

    /// Each font in the palette's Font… list takes over the terminal, which fits its card again in that
    /// face's cells; the list checks the one in use. The peek's pictures and the history overlay are drawn
    /// in the chosen face too. Xenon is chosen last, so the device is left on the default.
    @MainActor
    func testFontListSetsTheTerminalFace() throws {
        let (app, probe) = launch()
        let a = try fixture("a")
        try open(app, a)
        addTeardownBlock { @MainActor in self.chooseFont(app, "xenon") }
        let terminal = app.textViews["terminal"].firstMatch
        for face in ["neon", "argon", "krypton", "radon", "sfMono", "menlo", "xenon"] {
            chooseFont(app, face)
            hideKeyboard(app)
            let grids = settle(probe, "the terminal in \(face)") { $0.count == 1 && $0[0].face == face && !$0[0].focused }
            assertFits(grids, "the terminal in \(face)")
            keep("font-\(face)")
            if face == "menlo" {
                app.typeKey("\\", modifierFlags: [.command, .shift])
                XCTAssertTrue(app.descendants(matching: .any)["peek.grid"].firstMatch.waitForExistence(timeout: 10), "the grid never showed")
                sleep(3)
                keep("font-peek-menlo")
                app.descendants(matching: .any)["peek.mac.\(a)"].firstMatch.tap()
                XCTAssertTrue(app.descendants(matching: .any)["peek.grid"].firstMatch.waitForNonExistence(timeout: 10), "the grid stayed")
                let history = app.textViews["history"]
                terminal.swipeDown(velocity: .fast)
                XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
                sleep(2)
                keep("font-history-menlo")
                // History holds the grid until it closes, and no key sent from here closed it, so the app
                // starts again, still in Menlo, before the last face.
                app.terminate()
                app.launch()
                XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started again")
                try open(app, a)
            }
        }
    }

    /// Letters typed in order find a command even with letters between them: "nwsn" puts New Session
    /// first, with the letters it matched in bold.
    @MainActor
    func testPaletteFindsLooseLetters() throws {
        let (app, _) = launch()
        try open(app, try fixture("a"))
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the palette never opened")
        query.typeText("nwsn")
        let new = app.buttons["palette.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10), "New Session is not among the matches")
        sleep(1)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'palette.'")).allElementsBoundByIndex
        let first = rows.min { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(first?.identifier, "palette.new", "the first match for nwsn")
        keep("palette-nwsn")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "the palette stayed open")
    }

    /// With Reduce Motion on in Settings, zooming a card and opening the grid happen without sliding;
    /// tools/look.sh checks from the probe's log that each went without animating and that tmux got no
    /// width from partway through. Reduce Motion goes off again afterwards, whether the test passed or not.
    @MainActor
    func testReduceMotionStillsTheScreen() throws {
        addTeardownBlock { @MainActor in self.switchReduceMotion(false) }
        switchReduceMotion(false)
        let (app, probe) = launch()
        let a = try fixture("a")
        try open(app, a)

        switchReduceMotion(true)
        app.activate()
        // Back from Settings, the terminal takes keys again after a tap.
        app.textViews["terminal"].firstMatch.tap()
        XCTAssertTrue(waitForSample(probe, "reduceMotion") { $0 == 1 }, "Lhûn never saw Reduce Motion on")

        app.typeKey("d", modifierFlags: .command)
        let split = settle(probe, "split right") { $0.count == 2 && $0.contains { $0.session == a } }
        let twin = try XCTUnwrap(split.first { $0.session != a }?.session, "no second card")
        hideKeyboard(app)
        _ = settle(probe, "two cards with the keyboard down") { $0.count == 2 && focused($0) == nil }
        let top = header(app, a)
        top.doubleTap()
        let zoomed = settle(probe, "zoomed") { $0.map(\.session) == [a] }
        assertFits(zoomed, "zoomed")
        keep("zoom-reduce-motion")
        top.doubleTap()
        let restored = settle(probe, "restored") { Set($0.map(\.session)) == [a, twin] }
        assertFits(restored, "restored")

        app.typeKey("\\", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["peek.grid"].firstMatch.waitForExistence(timeout: 10), "the grid never showed")
        sleep(3)
        keep("peek-reduce-motion")
        app.descendants(matching: .any)["peek.mac.\(a)"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["peek.grid"].firstMatch.waitForNonExistence(timeout: 10), "the grid stayed")
    }

    // MARK: Steps

    @MainActor
    private func launch() -> (app: XCUIApplication, probe: XCUIElement) {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the sessions' pills are there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
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

    /// Opens the palette and types `text`, leaving the palette open.
    @MainActor
    private func search(_ app: XCUIApplication, _ text: String) {
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the palette never opened")
        query.typeText(text)
    }

    /// Turns Compact Layout on or off from the palette's Settings row, when it is not already.
    @MainActor
    private func setCompactLayout(_ app: XCUIApplication, _ on: Bool) {
        search(app, "compact layout")
        let row = app.buttons["palette.compact-layout"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Compact Layout row never showed")
        if row.value as? String == (on ? "on" : "off") {
            app.typeKey(".", modifierFlags: .command)
        } else {
            row.tap()
        }
        XCTAssertTrue(app.textFields["palette.query"].waitForNonExistence(timeout: 10), "the palette stayed open")
    }

    /// Chooses `face` from the palette's Font… list.
    @MainActor
    private func chooseFont(_ app: XCUIApplication, _ face: String) {
        search(app, "font")
        let font = app.buttons["palette.font"]
        XCTAssertTrue(font.waitForExistence(timeout: 10), "the Font… row never showed")
        font.tap()
        let row = app.buttons["palette.font.\(face)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(face) is not in the font list")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'palette.font.' AND value == 'current'")).count, 1,
                       "the font list should check one font")
        row.tap()
        XCTAssertTrue(app.textFields["palette.query"].waitForNonExistence(timeout: 10), "the palette stayed open")
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        XCTAssertTrue(OnScreenKeyboard(app).putDown(ifUpWithin: 10), "the keyboard never came up")
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["card.mac.\(name)"].firstMatch
    }

    /// Has tools/look.sh photograph the device's screen as `name`.png, and holds still until it has. The
    /// test asks with an empty file named for the shot in its own Documents, take-look-<name>, and
    /// tools/look.sh answers with taken-look-<name> once devicectl has saved the picture, which stands the
    /// way the iPad is held. The runner is shared, so the look- prefix keeps other tests' scripts off it.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-look-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-look-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the screenshot \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/look.sh never photographed \(name)")
    }

    private func fixture(_ suffix: String) throws -> String {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["LOOK_PREFIX"], "run this test through tools/look.sh")
        return "\(prefix)-\(suffix)"
    }

    // MARK: Probe

    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// Waits up to ten seconds for the probe's `key` to satisfy `accept`.
    @MainActor
    private func waitForSample(_ probe: XCUIElement, _ key: String, until accept: (Int) -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if let value = try? sample(probe)[key], accept(value) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// One terminal on screen as the probe reports it. The probe lists them in no particular order.
    private struct Grid: Equatable, CustomStringConvertible {
        let session: String
        let cols: Int
        let rows: Int
        let face: String
        let fit: String
        let card: [Double]
        let focused: Bool
        let resizes: Int

        var description: String {
            "\(session) \(cols)x\(rows) \(face) card \(card) focused \(focused) resizes \(resizes): \(fit)"
        }
    }

    private func focused(_ grids: [Grid]) -> String? {
        grids.first(where: \.focused)?.session
    }

    private func cols(_ grids: [Grid], _ session: String) -> Int {
        grids.first { $0.session == session }?.cols ?? .max
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
                face: grid["face"] as? String ?? "",
                fit: grid["fit"] as? String ?? "",
                card: (grid["card"] as? [NSNumber] ?? []).map(\.doubleValue),
                focused: (grid["focused"] as? NSNumber)?.boolValue ?? false,
                resizes: (grid["resizes"] as? NSNumber)?.intValue ?? -1
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
                if let previous, Set(previous.grids.map(\.description)) == Set(sample.grids.map(\.description)),
                   !sample.grids.isEmpty, accept(sample.grids) {
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
