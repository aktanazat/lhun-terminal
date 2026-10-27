import UniformTypeIdentifiers
import XCTest

/// A terminal workflow with the screen recorded. Run it through
/// tools/walk.sh, which makes the sessions, keeps the recording and lines it up with the steps:
/// <WALK_PREFIX>-omp runs omp in the repository, <WALK_PREFIX>-claude runs Claude Code in an empty folder,
/// and <WALK_PREFIX>-shell is a shell in the repository whose `drop` ends Lhûn's own connection to it. The
/// walk types into each, reads back through history, switches sessions by a tap, the keys, ⌘K, the palette's
/// button and the pulled-down pictures, splits two cards and drags the gap between them, turns the iPad the
/// other way and back, drops the connection, sends the app away and back, and goes through it again in
/// light. It holds the iPad sideways, or upright with WALK_HOLD=portrait. On a simulator, which has a
/// hardware keyboard throughout and so no key row, it presses the hardware keys the row stands in for.
/// Nothing it types reaches a model: questions to omp and Claude Code are taken back before they are
/// sent. Its assertions only check that each step got where it was going, so the recording shows what it
/// meant to.
final class LhunWalk: XCTestCase {
    @MainActor
    func testWalkthrough() throws {
        let walk = try Walk(self)
        let device = XCUIDevice.shared
        let appearance = device.appearance
        let orientation = device.orientation
        addTeardownBlock {
            await MainActor.run {
                device.appearance = appearance == .light ? .light : .dark
                device.orientation = switch orientation {
                case .landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown: orientation
                default: Walk.landscape(orientation)
                }
            }
        }
        let landscape = Walk.landscape(orientation)
        let (held, turned) = walk.upright ? (UIDeviceOrientation.portrait, landscape) : (landscape, .portrait)
        device.orientation = held
        device.appearance = .dark
        walk.launch()
        walk.useOmp()
        walk.useClaude()
        walk.useShell()
        walk.readHistory()
        walk.switchSessions()
        walk.splitAndResize()
        walk.turn(to: turned, andBackTo: held)
        walk.reconnect()
        walk.inLight()
        walk.finish()
    }
}

/// The walk's steps and what they leave behind: a screenshot at each pose worth a look, the moment each
/// step began (steps), and what the accessibility audit found at a few poses (audit).
@MainActor
private final class Walk {
    let test: XCTestCase
    let app = XCUIApplication()
    let omp: String
    let claude: String
    let shell: String
    /// Held upright rather than sideways (WALK_HOLD=portrait).
    let upright: Bool
    private let probe: XCUIElement
    private var steps: [String] = []
    private var findings: [String] = []
    /// Each open terminal's grid at a few poses: what the pose did to the sessions' sizes.
    private var grids: [String] = []
    private var shots = 0

    init(_ test: XCTestCase) throws {
        let environment = ProcessInfo.processInfo.environment
        let prefix = try XCTUnwrap(environment["WALK_PREFIX"], "run this test through tools/walk.sh")
        omp = "\(prefix)-omp"
        claude = "\(prefix)-claude"
        shell = "\(prefix)-shell"
        upright = environment["WALK_HOLD"] == "portrait"
        self.test = test
        probe = app.descendants(matching: .any)["probe"].firstMatch
    }

    /// The device held sideways the way it was, or the usual way when it lay flat.
    nonisolated static func landscape(_ orientation: UIDeviceOrientation) -> UIDeviceOrientation {
        orientation == .landscapeRight ? .landscapeRight : .landscapeLeft
    }

    /// Whether Lhûn shows its key row over the on-screen keyboard: not on a simulator, which has a hardware
    /// keyboard throughout.
    static let keyRow: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    // MARK: The walk

    func launch() {
        step("launch") {
            // The pills along the top, whatever layout the iPad last kept: the walk goes by the strip.
            app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-shares", "{}",
                                   "-layout", "tabs"]
            app.launch()
            XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
            for name in [omp, claude, shell] {
                let pill = app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
                XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(name) never showed in the strip")
            }
            dwell(3)
            shot("launch")
            audit("launch, dark")
        }
    }

    func useOmp() {
        step("omp: type a question, browse its commands, send nothing") {
            open(omp)
            draftAndBrowse("what does the readme say about the key row")
            shot("omp")
        }
    }

    func useClaude() {
        step("claude: type a question, browse its commands, send nothing") {
            open(claude)
            draftAndBrowse("what is in this folder")
            shot("claude")
        }
    }

    /// Types a question at the program's prompt and takes it back with the key row's control and the
    /// on-screen u, then opens the program's slash commands from the key row, moves down them and closes
    /// them with the key row's Escape. Nothing is sent.
    private func draftAndBrowse(_ question: String) {
        terminal.tap()
        expectKeyRow()
        app.typeText(question)
        dwell(2)
        expectKeyRow()
        control("u")
        dwell(1)
        rowKey("/", "/")
        dwell(1.5)
        for _ in 0..<3 {
            rowKey("Down", XCUIKeyboardKey.downArrow.rawValue)
            dwell(0.6)
        }
        dwell(1)
        rowKey("Escape", XCUIKeyboardKey.escape.rawValue)
        dwell(1)
        control("u")
        dwell(1)
    }

    /// The key row's control, then a letter on the on-screen keyboard; without the row, the hardware keys.
    private func control(_ letter: String) {
        guard Self.keyRow else {
            app.typeKey(letter, modifierFlags: .control)
            return
        }
        app.buttons["Control"].tap()
        keyboard.keys[letter].tap()
    }

    /// A key on the key row by its label; without the row, the hardware key it stands in for.
    private func rowKey(_ label: String, _ key: String) {
        if Self.keyRow {
            app.buttons[label].firstMatch.tap()
        } else {
            app.typeKey(key, modifierFlags: [])
        }
    }

    /// Typing from the test plugs in a hardware keyboard for a moment, which hides the on-screen one and
    /// the key row above it; they come back a moment later.
    private func expectKeyRow() {
        guard Self.keyRow else { return }
        let escape = app.buttons["Escape"].firstMatch
        let deadline = Date.now.addingTimeInterval(8)
        while !(escape.exists && escape.isHittable), Date.now < deadline {
            dwell(0.3)
        }
        XCTAssertTrue(escape.isHittable, "the key row never came up")
    }

    func useShell() {
        step("shell: type commands") {
            open(shell)
            terminal.tap()
            dwell(2)
            // Two letters and Return on the on-screen keyboard, the way a finger types them, then the key
            // row's up arrow and Return to run it again.
            let returnKey = keyboard.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", "return")).firstMatch
            if Self.keyRow {
                for letter in ["l", "s"] {
                    keyboard.keys[letter].tap()
                }
                returnKey.tap()
            } else {
                app.typeText("ls\n")
            }
            waitForQuiet()
            dwell(1)
            rowKey("Up", XCUIKeyboardKey.upArrow.rawValue)
            dwell(1)
            if Self.keyRow {
                returnKey.tap()
            } else {
                app.typeText("\n")
            }
            waitForQuiet()
            dwell(1)
            app.typeText("git --no-pager log --stat -40\n")
            waitForQuiet()
            dwell(2)
            shot("shell")
        }
    }

    func readHistory() {
        step("history: read back through the output") {
            let history = app.textViews["history"]
            terminal.swipeDown(velocity: .fast)
            XCTAssertTrue(history.waitForExistence(timeout: 10), "history never opened")
            for _ in 0..<4 {
                history.swipeDown()
                dwell(1)
            }
            shot("history")
            for _ in 0..<20 where history.exists {
                history.swipeUp(velocity: .fast)
                dwell(0.6)
            }
            XCTAssertTrue(history.waitForNonExistence(timeout: 5), "scrolling to the bottom never brought the terminal back")
            dwell(2)
        }
    }

    func switchSessions() {
        step("switch: a tap on a pill") {
            for name in [omp, claude, shell] {
                pill(name).tap()
                expectSelection(name)
                dwell(2)
            }
        }
        step("switch: ⌘⇧[ and ⌘⇧]") {
            // The strip sorts by name: claude, omp, shell.
            for (key, name) in [("[", omp), ("[", claude), ("]", omp), ("]", shell)] {
                app.typeKey(key, modifierFlags: [.command, .shift])
                expectSelection(name)
                dwell(1.5)
            }
        }
        step("switch: ⌘K") {
            let query = app.textFields["palette.query"]
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette")
            dwell(1.5)
            shot("palette")
            audit("palette, dark")
            query.typeText("polish-omp")
            dwell(1.5)
            shot("palette-typed")
            query.typeText("\n")
            expectSelection(omp)
            dwell(2)
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette again")
            query.typeText("polish-shell\n")
            expectSelection(shell)
            dwell(2)
        }
        step("switch: the palette from its button, over the on-screen keyboard") {
            terminal.tap()
            expectKeyRow()
            dwell(1)
            noteGrids("keyboard up, before the palette")
            app.descendants(matching: .any)["palette"].firstMatch.tap()
            XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 10), "the strip's button never opened the palette")
            dwell(1.5)
            noteGrids("palette open over the keyboard")
            shot("palette-touch")
            // Only the rows in sight are drawn, and Claude Code's session lists among the agents, below the
            // other sessions, so its name narrows the list first.
            app.textFields["palette.query"].typeText(claude)
            let row = app.descendants(matching: .any)["palette.open.mac.\(claude)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette lists no \(claude)")
            row.tap()
            expectSelection(claude)
            dwell(2)
            noteGrids("after the palette")
            pill(shell).tap()
            expectSelection(shell)
            dwell(1.5)
        }
        step("switch: the pulled-down pictures") {
            let row = app.descendants(matching: .any)["peek.row"].firstMatch
            let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
            pullStrip(170)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "a short pull from the strip showed no pictures")
            dwell(2.5)
            shot("peek-row")
            pullStrip(320)
            XCTAssertTrue(grid.waitForExistence(timeout: 5), "a long pull showed no grid")
            dwell(2.5)
            shot("peek-grid")
            let picture = app.descendants(matching: .any)["peek.mac.\(omp)"].firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout: 5), "the grid has no picture of \(omp)")
            if picture.isHittable {
                picture.tap()
                expectSelection(omp)
            } else {
                XCTFail("the picture of \(omp) is off the screen")
            }
            dwell(2)
            pill(shell).tap()
            expectSelection(shell)
            dwell(2)
        }
    }

    func splitAndResize() {
        step("split: a card to the right") {
            app.typeKey("d", modifierFlags: .command)
            expectCards(2)
            dwell(2)
            app.typeText("ls\n")
            dwell(2)
            app.typeKey("[", modifierFlags: .command)
            dwell(1.5)
            app.typeKey("]", modifierFlags: .command)
            dwell(1.5)
            shot("split")
            audit("split, dark")
        }
        step("split: drag the gap") {
            hideKeyboard()
            dwell(1.5)
            dragGap(by: -0.18)
            dwell(2)
            dragGap(by: 0.3)
            dwell(2)
            shot("gap")
        }
        step("split: zoom and back") {
            let header = app.descendants(matching: .any)["card.mac.\(shell)"].firstMatch
            header.doubleTap()
            expectCards(1)
            dwell(2)
            shot("zoom")
            header.doubleTap()
            expectCards(2)
            dwell(2)
        }
        step("split: close, then stack") {
            app.typeKey("]", modifierFlags: .command)
            dwell(1)
            app.typeKey("w", modifierFlags: .command)
            expectCards(1)
            dwell(2)
            app.typeKey("d", modifierFlags: [.command, .shift])
            expectCards(2)
            dwell(2)
            app.typeText("ls\n")
            dwell(2)
            shot("stacked")
            app.typeKey("w", modifierFlags: .command)
            expectCards(1)
            dwell(2)
        }
    }

    /// Turns the iPad to `turned`, types and opens the palette there, then turns it back to `held`.
    func turn(to turned: UIDeviceOrientation, andBackTo held: UIDeviceOrientation) {
        let there = turned.isPortrait ? "portrait" : "landscape"
        let back = held.isPortrait ? "portrait" : "landscape"
        step("turn to \(there) and back") {
            XCUIDevice.shared.orientation = turned
            dwell(4)
            terminal.tap()
            dwell(1)
            app.typeText("ls\n")
            dwell(2)
            shot(there)
            app.typeKey("k", modifierFlags: .command)
            dwell(2)
            shot("\(there)-palette")
            audit("palette, \(there)")
            app.typeKey("k", modifierFlags: .command)
            dwell(1.5)
            XCUIDevice.shared.orientation = held
            dwell(4)
            shot("\(back)-again")
        }
    }

    func reconnect() {
        step("reconnect: the connection drops") {
            let status = app.staticTexts["status"]
            // Only the shell has `drop`, and the split before this leaves the session it opened beside the
            // shell on screen.
            open(shell)
            let before = reconnects
            terminal.tap()
            dwell(1)
            app.typeText("drop\n")
            if status.waitForExistence(timeout: 10) {
                shot("reconnecting")
            }
            XCTAssertTrue(status.waitForNonExistence(timeout: 30), "the session never came back after the drop")
            let deadline = Date.now.addingTimeInterval(20)
            while reconnects <= before, Date.now < deadline {
                dwell(0.3)
            }
            XCTAssertGreaterThan(reconnects, before, "the probe saw no reconnect")
            dwell(3)
        }
        step("reconnect: away and back") {
            XCUIDevice.shared.press(.home)
            dwell(6)
            app.activate()
            dwell(1)
            shot("back")
            XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never came back from the background")
            dwell(3)
        }
    }

    func inLight() {
        step("light: the same again in light") {
            XCUIDevice.shared.appearance = .light
            dwell(3)
            shot("light-shell")
            audit("shell, light")
            pill(omp).tap()
            expectSelection(omp)
            dwell(3)
            shot("light-omp")
            app.typeKey("k", modifierFlags: .command)
            dwell(2)
            shot("light-palette")
            audit("palette, light")
            app.typeKey("k", modifierFlags: .command)
            dwell(1.5)
            app.typeKey("d", modifierFlags: .command)
            expectCards(2)
            dwell(3)
            shot("light-split")
            audit("split, light")
            app.typeKey("w", modifierFlags: .command)
            expectCards(1)
            dwell(2)
            XCUIDevice.shared.appearance = .dark
            dwell(3)
            shot("dark-again")
        }
    }

    /// Leaves the steps, the audit's findings and the grids in the result bundle.
    func finish() {
        keep(steps.joined(separator: "\n") + "\n", as: "steps")
        keep(findings.joined(separator: "\n") + "\n", as: "audit")
        keep(grids.joined(separator: "\n") + "\n", as: "grids")
    }

    // MARK: Steps

    /// Runs a step as an activity in the result bundle, noting when it began.
    private func step(_ name: String, _ body: () -> Void) {
        steps.append("\(name)\t\(Date.now.timeIntervalSince1970)")
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// Holds still the way a person reads what came up.
    private func dwell(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func noteGrids(_ pose: String) {
        let open = (sample()["grids"] as? [[String: Any]] ?? []).map { grid in
            "\(grid["session"] ?? "?") \(grid["cols"] ?? "?")x\(grid["rows"] ?? "?")"
        }
        grids.append("\(pose)\t\(open.joined(separator: ", "))")
    }

    private var terminal: XCUIElement {
        app.textViews["terminal"].firstMatch
    }

    private var keyboard: XCUIElement {
        app.keyboards.firstMatch
    }

    /// The session's pill, scrolled into view.
    private func pill(_ name: String) -> XCUIElement {
        test.onStrip(app, name)
    }

    /// Opens the session with its pill and waits for it to attach.
    private func open(_ name: String) {
        pill(name).tap()
        expectSelection(name)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "\(name) showed no terminal")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        dwell(2)
    }

    /// Puts the on-screen keyboard down with the key row's Hide Keyboard, or the keyboard's own key where
    /// there is no row.
    private func hideKeyboard() {
        let hide = app.buttons.matching(NSPredicate(format: "label ==[c] 'Hide keyboard'")).firstMatch
        if hide.waitForExistence(timeout: 3) {
            hide.tap()
        }
    }

    /// From just left of the strip's glyphs, pulls down by `distance` points and lets go.
    private func pullStrip(_ distance: CGFloat) {
        let palette = app.descendants(matching: .any)["palette"].firstMatch
        let strip = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: palette.frame.minX - 4, dy: palette.frame.midY))
        strip.press(
            forDuration: 0.2, thenDragTo: strip.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: XCUIGestureVelocity(distance < 300 ? 300 : 600), thenHoldForDuration: 0.5
        )
    }

    /// Drags the gap between two cards side by side by a share of the window's width, at a finger's pace.
    private func dragGap(by share: CGFloat) {
        let gap = app.descendants(matching: .any)["gap"].firstMatch
        XCTAssertTrue(gap.waitForExistence(timeout: 5), "no gap between the cards")
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: gap.frame.midX, dy: gap.frame.midY))
        let distance = share * app.windows.firstMatch.frame.width
        from.press(
            forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: distance, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.4
        )
    }

    /// A screenshot of the whole screen, numbered in the order taken and turned the way the device is held:
    /// XCTest takes the screen as the panel lies, upright in portrait.
    private func shot(_ name: String) {
        shots += 1
        let screen = XCUIScreen.main.screenshot().image
        let turn: UIImage.Orientation = switch XCUIDevice.shared.orientation {
        case .landscapeLeft: .left
        case .landscapeRight: .right
        case .portraitUpsideDown: .down
        default: .up
        }
        var upright = screen
        if turn != .up, screen.size.width < screen.size.height, let pixels = screen.cgImage {
            upright = UIImage(cgImage: pixels, scale: screen.scale, orientation: turn)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        let png = UIGraphicsImageRenderer(size: upright.size, format: format).pngData { _ in upright.draw(at: .zero) }
        let shot = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
        shot.name = String(format: "%02d-%@", shots, name)
        shot.lifetime = .keepAlways
        test.add(shot)
    }

    private func keep(_ text: String, as name: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        test.add(note)
    }

    /// Notes what the accessibility audit finds on screen: contrast, targets too small to hit, clipped
    /// text and controls with no description. The findings go to `audit`; none fails the walk.
    private func audit(_ pose: String) {
        var found: [String] = []
        do {
            try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .textClipped, .sufficientElementDescription]) { issue in
                // A snapshot, for the element may have gone since the audit saw it, as a pill's text does
                // when its session's command changes, and reading a gone element's frame fails the walk.
                let element = try? issue.element?.snapshot()
                let frame = element.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""
                found.append([pose, Self.name(of: issue.auditType), issue.compactDescription, element?.identifier ?? "", element?.label ?? "", frame]
                    .joined(separator: "\t"))
                return true
            }
        } catch {
            found.append("\(pose)\tthe audit failed: \(error)")
        }
        findings += found.isEmpty ? ["\(pose)\tnothing found"] : found
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .hitRegion: "hit region"
        case .textClipped: "text clipped"
        case .sufficientElementDescription: "description"
        default: "type \(type.rawValue)"
        }
    }

    // MARK: Probe

    private func sample() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]) ?? [:]
    }

    private var selection: String? {
        (sample()["selection"] as? [String: String])?["name"]
    }

    private var reconnects: Int {
        (sample()["reconnects"] as? [Any])?.count ?? 0
    }

    private func expectSelection(_ name: String) {
        let deadline = Date.now.addingTimeInterval(15)
        while selection != name, Date.now < deadline {
            dwell(0.3)
        }
        XCTAssertEqual(selection, name, "the session open")
    }

    /// Waits for `count` terminals on screen, the same in two samples in a row.
    private func expectCards(_ count: Int) {
        let deadline = Date.now.addingTimeInterval(20)
        var last = -1
        while Date.now < deadline {
            let now = (sample()["grids"] as? [Any])?.count ?? 0
            if now == count, last == count { return }
            last = now
            dwell(0.5)
        }
        XCTFail("waited for \(count) cards; the probe last showed \(last)")
    }

    /// Waits until no output has reached the terminals for a second and a half.
    private func waitForQuiet() {
        let deadline = Date.now.addingTimeInterval(20)
        var last = sample()["bytesFed"] as? Int
        var since = Date.now
        while Date.now < deadline {
            dwell(0.25)
            let fed = sample()["bytesFed"] as? Int
            if fed != last {
                last = fed
                since = .now
            } else if Date.now.timeIntervalSince(since) >= 1.5 {
                return
            }
        }
    }
}
