import CryptoKit
import XCTest

/// Reads back through tmux's history on a real device, against a session on the Mac that tools/history.sh
/// fills with 3,000 numbered, colored lines, and selects and pastes on the live terminal of a second
/// session. Has tools/history.sh photograph each step: history several hundred lines back, a find match, a
/// stretch selected for copying, the terminal back after typing with the copied word pasted at the prompt,
/// a word and a row selected on the live terminal, the line typed once the find bar closed, and the
/// question a paste of several lines asks. The test runner cannot read the device's clipboard, so copies
/// are checked by the size and SHA-256 the app's probe reports (ProbeCopies.swift).
/// tools/history.sh checks meanwhile that tmux never enters copy mode and that the shell ran what was
/// typed, and reads the footprint before, during and after from the probe log.
final class LhunHistory: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// With history open over the terminal, ⌘F opens the find bar. Done closes the bar and gives the keys
    /// back to the terminal with its keyboard and key row, so the next key takes history away and reaches
    /// the shell with no tap. tools/history.sh checks the shell ran the line.
    @MainActor
    func testFindBarGivesTheKeysBack() throws {
        let (app, probe, terminal) = try open("HISTORY_SESSION")
        let history = app.textViews["history"]
        terminal.swipeDown(velocity: .fast)
        XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
        sleep(2)
        app.typeKey("f", modifierFlags: .command)
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@",
            [XCUIElement.ElementType.searchField, .textField].map { NSNumber(value: $0.rawValue) }
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar never opened")
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the find bar shows no Done or Close button")
        done.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the find bar never closed")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard stayed away once the find bar closed")
        XCTAssertTrue(OnScreenKeyboard(app).up(within: 5), "the key row stayed away once the find bar closed")
        // Hidden under history, the terminal is nothing XCUITest types text into; typeKey goes to whatever
        // has the keys.
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(history.waitForNonExistence(timeout: 5), "history stayed after typing once the find bar closed")
        run("cho typed-after-find", app, probe)
        keep("7-find-typed")
    }

    /// On the live terminal, a long press copies the word under it and a long press dragged along a row
    /// copies the row; a tap away takes the selection off.
    @MainActor
    func testLongPressSelectsOnTheLiveTerminal() throws {
        let (app, probe, terminal) = try open("LIVE_SESSION")
        let cell = try cellSize(probe)
        let selection = app.textViews["selection"]
        func at(_ column: Double, _ row: Double, on element: XCUIElement) -> XCUICoordinate {
            self.at(column, row, on: element, cell: cell)
        }

        run("clear; echo alpha bravo charlie", app, probe)
        var before = copied(probe)
        at(8, 0, on: terminal).press(forDuration: 1.2)
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the long press laid nothing over the terminal")
        chooseFromMenu("Copy", app, "the long-pressed word", keeping: "5-word")
        assertCopied("bravo", probe: probe, since: before, after: "the long press on the second word")
        at(30, 8, on: selection).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5), "a tap away left the word selected")

        run("clear; echo one two three four", app, probe)
        before = copied(probe)
        at(0, 0, on: terminal).press(forDuration: 1.2, thenDragTo: at(17, 0, on: terminal))
        chooseFromMenu("Copy", app, "the dragged row", keeping: "6-line")
        assertCopied("one two three four", probe: probe, since: before, after: "the long press dragged to the end of the row")
        at(30, 8, on: selection).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 5), "a tap away left the row selected")
    }

    /// Text of more than one line pasted into a program that does not take pastes as one piece, as cat
    /// does not, would run each line as it lands, so Lhûn asks first: Cancel sends nothing, Paste sends it.
    /// tmux, which says what the pane's program takes, keeps bracketed paste on with the device and takes
    /// the frame off for cat, so the text goes framed either way. At the shell's prompt, which takes pastes
    /// as one piece, it goes in without asking. A program's copy (OSC 52) puts the text on the clipboard.
    @MainActor
    func testMultiLinePasteAsksFirst() throws {
        let (app, probe, terminal) = try open("LIVE_SESSION")
        let cell = try cellSize(probe)
        let ask = app.alerts["Paste and Run?"]
        let framed = "\u{1B}[200~paste-one\npaste-two\u{1B}[201~"
        run("printf '\\e]52;c;%s\\a' \(Data("paste-one\npaste-two".utf8).base64EncodedString())", app, probe)

        run("cat", app, probe)
        let before = sentCount(probe)
        pasteFromMenu(app, terminal, cell: cell)
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "two lines pasted into cat went in without asking")
        keep("8-paste-asks")
        ask.buttons["Cancel"].tap()
        XCTAssertTrue(ask.waitForNonExistence(timeout: 5), "Cancel left the question up")
        // The terminal still answers on its own meanwhile (focus, size), so only the paste's text counts.
        XCTAssertFalse(sent("paste-one", probe, since: before), "Cancel still sent the paste")
        pasteFromMenu(app, terminal, cell: cell)
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "the second paste into cat went in without asking")
        ask.buttons["Paste"].tap()
        XCTAssertTrue(sent(framed, probe, since: before), "Paste did not send the lines")
        app.typeKey("c", modifierFlags: .control)

        run("", app, probe)
        let atPrompt = sentCount(probe)
        pasteFromMenu(app, terminal, cell: cell)
        XCTAssertTrue(sent(framed, probe, since: atPrompt), "a paste at the shell's prompt was not sent")
        XCTAssertFalse(ask.exists, "a paste at the shell's prompt asked first")
        app.typeKey("c", modifierFlags: .control)
    }

    /// Swipes several hundred rows back and finds the one line with "needle" through ⌘F. Copies a stretch
    /// of rows, then a word, and types: the first key takes history away and reaches the shell, the copied
    /// word is pasted after it, and history lets go of everything it read. With the keyboard hidden, a tap
    /// on the terminal gives it back.
    @MainActor
    func testReadingBackThroughHistory() throws {
        let (app, probe, terminal) = try open("HISTORY_SESSION")

        // Swipes down until the view is several hundred rows back, past the first 500 lines read.
        let history = app.textViews["history"]
        terminal.swipeDown(velocity: .fast)
        XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
        var back = 0
        for _ in 0..<40 where back < 700 {
            history.swipeDown(velocity: .fast)
            sleep(2)
            back = historySample(probe)["back"] ?? 0
        }
        let open = historySample(probe)
        XCTAssertGreaterThanOrEqual(open["back"] ?? 0, 700, "rows back from the bottom")
        XCTAssertGreaterThan(open["rows"] ?? 0, 500, "older lines never loaded")
        keep("1-history")

        // ⌘F opens history's find bar. The needle is 400 lines from the end, below the rows on screen.
        // Typing into the bar from XCUITest hides the on-screen keyboard and shows it again, and the match
        // the bar scrolled to as the word went in ended up under the keyboard as it came back. Once the
        // keyboard holds still, the bar's Next Result brings the match into view.
        XCTAssertFalse((history.value as? String ?? "").contains("needle"), "the needle showed before it was looked for")
        app.typeKey("f", modifierFlags: .command)
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@",
            [XCUIElement.ElementType.searchField, .textField].map { NSNumber(value: $0.rawValue) }
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar never opened")
        field.typeText("needle")
        settledKeyboard(probe)
        let next = app.buttons.matching(NSPredicate(format: "label == %@", "Next Result")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the find bar shows no Next Result button")
        next.tap()
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "the needle is here"), object: history)
        XCTAssertEqual(XCTWaiter().wait(for: [match], timeout: 10), .completed, "the match never came into view")
        keep("2-find")
        // Esc from XCUITest never reaches the app while the on-screen keyboard shows; the bar's own button
        // closes it.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the find bar shows no Done or Close button")
        close.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the find bar never closed")
        // The keys went back to where they were before the bar opened; the card stops resizing for the
        // keyboard before anything is selected.
        settledKeyboard(probe)

        // A long press and a drag down copy everything between, lines whole and wrapped rows joined: some
        // stretch of the lines tools/history.sh wrote. The end of the selection stays above the finger (a
        // drag two rows down kept it on the first row), so the drag goes six rows down. After a tap clears
        // that, a long press copies the one word under the finger, near the start of a row.
        let cell = try cellSize(probe)
        let row = history.frame.height * 0.4
        let origin = history.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: cell.width / 2, dy: row))
        var before = copied(probe)
        start.press(forDuration: 1.2, thenDragTo: start.withOffset(CGVector(dx: cell.width * 20, dy: cell.height * 6)))
        chooseFromMenu("Copy", app, "the stretch dragged across", keeping: "3-selection")
        let stretch = try XCTUnwrap(nextCopy(probe, since: before), "copying the stretch put nothing on the clipboard")
        XCTAssertGreaterThan(stretch.bytes, 40, "the drag never took the selection past the first word: \(stretch)")
        XCTAssertTrue(Self.seedHolds(stretch), "the copied stretch is not the lines as written: \(stretch)")
        origin.withOffset(CGVector(dx: cell.width * 30, dy: history.frame.height * 0.8)).tap()
        before = copied(probe)
        origin.withOffset(CGVector(dx: cell.width * 2.5, dy: row)).press(forDuration: 1.2)
        chooseFromMenu("Copy", app, "the long-pressed word")
        let word = try XCTUnwrap(nextCopy(probe, since: before), "copying the word put nothing on the clipboard")
        XCTAssertTrue((1...9).contains(word.bytes) && Self.seedHolds(word), "the long press copied more than a word of the lines: \(word)")

        // A key typed goes to the terminal and takes history away. The terminal is hidden under history,
        // and XCUITest types text only into an element it sees; typeKey sends the key as a hardware
        // keyboard does, to whatever has the keyboard. The rest of the line and the copied word follow once
        // the terminal shows: tools/history.sh checks the shell echoed the word, so the first key reached it
        // too.
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(history.waitForNonExistence(timeout: 5), "history stayed after typing")
        app.typeText("cho ")
        app.typeKey("v", modifierFlags: .command)
        run("", app, probe)
        keep("4-typed")
        // UIKit keeps the view its edit menu last showed from, and clears it on a 60-second timer
        // (_UIMenuPresentationSourceSceneComponent), so history lets go about a minute after the word's
        // Copy menu rather than when it closes.
        waitForProbe(probe, "the probe to report history let go", within: 80) { $0.isEmpty }

        // The key row's button takes the keyboard from the terminal; a tap on the terminal gives it back.
        // tools/history.sh checks the shell ran the line typed after the tap.
        let keyboard = OnScreenKeyboard(app)
        XCTAssertTrue(keyboard.up(within: 5), "no Hide Keyboard button over the keyboard")
        keyboard.hide.tap()
        XCTAssertTrue(keyboard.down(within: 5), "the keyboard stayed up")
        terminal.tap()
        XCTAssertTrue(keyboard.up(within: 5), "a tap on the terminal brought no keyboard")
        run("echo typed-after-tap", app, probe)

        // A few more samples after closing, for tools/history.sh to read the footprint once it settles.
        let since = probeTime(probe)
        waitForProbe(probe, "five more seconds of samples") { _ in probeTime(probe) >= since + 5 }
    }

    // MARK: Steps

    /// Launches Lhûn with the probe on and opens the session named in the environment variable, attached.
    /// One key goes first: XCUITest's first hides the on-screen keyboard and shows it again, resizing the
    /// card, so that is over before anything is measured.
    @MainActor
    private func open(_ variable: String) throws -> (app: XCUIApplication, probe: XCUIElement, terminal: XCUIElement) {
        let session = try XCTUnwrap(ProcessInfo.processInfo.environment[variable], "run this test through tools/history.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-host", "mac", "-probe", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let row = app.descendants(matching: .any)["session.mac.\(session)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(session) never appeared")
        row.tap()
        // The session list's icons carry the same identifier; the terminal is the text view.
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        settledGrid(probe)
        return (app, probe, terminal)
    }

    /// Types the rest of a command line and Return, and waits for the shell's output to stop arriving.
    @MainActor
    private func run(_ command: String, _ app: XCUIApplication, _ probe: XCUIElement) {
        let before = bytesFed(probe)
        app.typeText(command + "\n")
        let deadline = Date.now.addingTimeInterval(20)
        var last = (bytes: before, since: Date.now)
        while Date.now < deadline {
            let bytes = bytesFed(probe)
            if bytes != last.bytes {
                last = (bytes, .now)
            } else if bytes > before, Date.now.timeIntervalSince(last.since) >= 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the shell's output to \(command.debugDescription) never stopped arriving; \(last.bytes) bytes in, \(before) before")
    }

    /// Taps `item` in the menu a long press shows, with a screenshot of the selection first when `name` is
    /// given. An alert the item brings up may hold a button of the same name; only the menu's must go.
    @MainActor
    private func chooseFromMenu(_ item: String, _ app: XCUIApplication, _ what: String, keeping name: String? = nil) {
        let named = NSPredicate(format: "label == %@", item)
        let found = app.descendants(matching: .any).matching(named)
        XCTAssertTrue(found.firstMatch.waitForExistence(timeout: 5), "\(what): no \(item) in the menu")
        if let name { keep(name) }
        let button = found.allElementsBoundByIndex.first { $0.isHittable } ?? found.firstMatch
        button.tap()
        let inAlerts = app.alerts.descendants(matching: .any).matching(named)
        let deadline = Date.now.addingTimeInterval(5)
        while found.count > inAlerts.count, Date.now < deadline { usleep(100_000) }
        XCTAssertEqual(found.count, inAlerts.count, "\(what): the menu stayed after \(item)")
    }

    /// Pastes through the menu a long press on a blank stretch of the terminal shows, which goes into the
    /// terminal as a typed paste does. XCTest's ⌘V pastes nothing into Lhûn on a simulator.
    @MainActor
    private func pasteFromMenu(_ app: XCUIApplication, _ terminal: XCUIElement, cell: CGSize) {
        at(30, 8, on: terminal, cell: cell).press(forDuration: 1.2)
        chooseFromMenu("Paste", app, "the long press on a blank row")
    }

    /// The middle of a cell of the terminal, or of the screen a long press lays over it in its place:
    /// hidden under that screen, the terminal is nowhere to touch.
    @MainActor
    private func at(_ column: Double, _ row: Double, on element: XCUIElement, cell: CGSize) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (column + 0.5) * cell.width, dy: (row + 0.5) * cell.height))
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

    /// The open history overlay as the probe reports it: rows held, rows back from the bottom, the slowest
    /// older stretch in milliseconds. Empty once it has closed and let go of what it read.
    @MainActor
    private func historySample(_ probe: XCUIElement) -> [String: Int] {
        guard let history = sample(probe)?["history"] as? [String: Any] else { return [:] }
        return history.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    @MainActor
    private func sample(_ probe: XCUIElement) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
    }

    /// Bytes the terminals have taken in from their sessions.
    @MainActor
    private func bytesFed(_ probe: XCUIElement) -> Int {
        (sample(probe)?["bytesFed"] as? NSNumber)?.intValue ?? 0
    }

    /// Bytes Lhûn has written to its sessions.
    @MainActor
    private func sentCount(_ probe: XCUIElement) -> Int {
        (sample(probe)?["sentCount"] as? NSNumber)?.intValue ?? 0
    }

    /// Whether `text` went out to the session within five seconds, among the bytes sent since the probe
    /// had counted `before`.
    @MainActor
    private func sent(_ text: String, _ probe: XCUIElement, since before: Int) -> Bool {
        let hex = text.utf8.map { String(format: "%02x", $0) }.joined()
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            if let latest = sample(probe), let count = (latest["sentCount"] as? NSNumber)?.intValue,
               count - before >= text.utf8.count, (latest["sent"] as? String)?.contains(hex) == true {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < deadline
        return false
    }

    /// Seconds since launch of the latest sample.
    @MainActor
    private func probeTime(_ probe: XCUIElement) -> Double {
        (sample(probe)?["t"] as? NSNumber)?.doubleValue ?? 0
    }

    /// Waits up to `seconds` for the history sample to pass `accept`, and returns it.
    @MainActor
    @discardableResult
    private func waitForProbe(
        _ probe: XCUIElement, _ what: String, within seconds: TimeInterval = 20,
        until accept: ([String: Int]) -> Bool
    ) -> [String: Int] {
        let deadline = Date.now.addingTimeInterval(seconds)
        var last = historySample(probe)
        while Date.now < deadline {
            last = historySample(probe)
            if accept(last) { return last }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("waited \(Int(seconds)) seconds for \(what); the probe last showed \(last)")
        return last
    }

    /// The terminal's grid once two samples in a row agree on it: the card has stopped changing size.
    @MainActor
    @discardableResult
    private func settledGrid(_ probe: XCUIElement) -> [String: Any] {
        let deadline = Date.now.addingTimeInterval(20)
        var previous: (t: Double, grid: NSDictionary)?
        while Date.now < deadline {
            if let latest = sample(probe), let t = (latest["t"] as? NSNumber)?.doubleValue, t != previous?.t,
               let grid = (latest["grids"] as? [[String: Any]])?.first {
                if let previous, previous.grid.isEqual(to: grid) { return grid }
                previous = (t, grid as NSDictionary)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the terminal's grid never settled; last \(previous?.grid.description ?? "nothing")")
        return [:]
    }

    /// Waits for the on-screen keyboard to hold still for a second, by where the probe last saw its top.
    @MainActor
    private func settledKeyboard(_ probe: XCUIElement) {
        let deadline = Date.now.addingTimeInterval(20)
        var last = (top: sample(probe)?["keyboard"] as? NSNumber, since: Date.now)
        while Date.now < deadline {
            let top = sample(probe)?["keyboard"] as? NSNumber
            if top != last.top {
                last = (top, .now)
            } else if Date.now.timeIntervalSince(last.since) >= 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the keyboard never held still; its top was last at \(last.top?.description ?? "nothing")")
    }

    /// One character cell of the terminal on screen, in points.
    @MainActor
    private func cellSize(_ probe: XCUIElement) throws -> CGSize {
        let cell = try XCTUnwrap(settledGrid(probe)["cell"] as? [NSNumber], "the probe shows no cell size")
        XCTAssertEqual(cell.count, 2, "the probe's cell size")
        return CGSize(width: cell[0].doubleValue, height: cell[1].doubleValue)
    }

    // MARK: Seed

    /// The lines tools/history.sh writes, colors aside, as a copy gives them, in UTF-8: one after another,
    /// each without the blanks at its end.
    private static let seed = Array((1...3000).map { seedLine($0) }.joined(separator: "\n").utf8)

    /// Whether a copy held some stretch of the seed's text, found by its size and SHA-256.
    private static func seedHolds(_ copy: ProbeCopy) -> Bool {
        guard (1...seed.count).contains(copy.bytes) else { return false }
        let digest = stride(from: 0, to: copy.sha256.count, by: 2).compactMap { offset -> UInt8? in
            let start = copy.sha256.index(copy.sha256.startIndex, offsetBy: offset)
            return UInt8(copy.sha256[start..<copy.sha256.index(start, offsetBy: 2)], radix: 16)
        }
        return (0...(seed.count - copy.bytes)).contains { start in
            SHA256.hash(data: seed[start..<start + copy.bytes]).elementsEqual(digest)
        }
    }

    private static func seedLine(_ number: Int) -> String {
        let body: String
        if number == 2600 {
            body = "the needle is here among the hay"
        } else {
            switch number % 8 {
            case 0: body = "plain words in the default color, quick brown foxes over lazy dogs"
            case 1: body = "red then bold green then blue and bold yellow"
            case 2: body = "orange azure lilac from the 256-color cube"
            case 3: body = "violet mint in 24-bit color"
            case 4: body = " red behind   inverse   white on blue"
            case 5: body = "wide 漢字 かな 한글 cells take two columns each"
            case 6: body = "a long line that wraps " + (0..<40).map { String(format: "word%02d", $0) }.joined(separator: " ")
            default: body = "italic underlined struck bold italic"
            }
        }
        return String(format: "%05d ", number) + body
    }

    // MARK: Screenshots

    /// Has tools/history.sh photograph the device's screen as `name`.png, and holds still until it has. The
    /// test asks with an empty file named for the shot in its own Documents, and tools/history.sh answers
    /// with another once devicectl has saved the picture, which stands the way the iPad is held: XCTest's
    /// own screenshots come out on their side.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the screenshot \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/history.sh never photographed \(name)")
    }
}
