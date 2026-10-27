import XCTest

/// The scenes of the side-by-side sheet, in landscape and then in portrait (tools/scenes.sh): an omp session,
/// a Claude Code session, two cards side by side, and the palette open over them. Then Lhûn in the iPad's own
/// windows, and the iPad put back to Full Screen Apps after them. tools/scenes.sh makes the sessions on the
/// Mac, <SCENES_PREFIX>-omp, -claude and -log, sets the appearance, and photographs each scene a test holds
/// still for.
final class LhunScenes: XCTestCase {
    /// The window's poses, smallest first, each with the share of the screen's width its corner handle sizes
    /// it to: none, the handle as far up and left as it goes, where the system stops it at the smallest window
    /// it allows; a third; and half, the size Split View gives an app too. The last two keep the screen's full
    /// height.
    private static let poses: [(name: String, share: CGFloat?)] = [("smallest", nil), ("third", 1 / 3), ("half", 1 / 2)]

    @MainActor
    func testScenes() throws {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["SCENES_PREFIX"], "run this test through tools/scenes.sh")
        let (omp, claude, log) = ("\(prefix)-omp", "\(prefix)-claude", "\(prefix)-log")
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-shares", "{}"]
        app.launch()

        for (orientation, turn) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)  // the turn has finished

            try open(app, omp)
            keep("1-omp-\(turn)")
            try open(app, claude)
            keep("2-claude-\(turn)")

            try open(app, omp)
            drop(app, log, at: CGVector(dx: 0.75, dy: 0.55))
            XCTAssertTrue(header(app, log).waitForExistence(timeout: 30), "\(log) never opened beside \(omp)")
            XCTAssertTrue(header(app, omp).exists, "\(omp) left when \(log) opened beside it")
            keyboardDown(app)
            sleep(2)  // both cards have drawn
            keep("3-split-\(turn)")

            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 10), "⌘K opened no palette")
            sleep(1)  // the palette has finished opening
            keep("4-palette-\(turn)")
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(app.textFields["palette.query"].waitForNonExistence(timeout: 10), "⌘K left the palette open")
            // The focused card, the log's, closes with Detach, since ⌘W would end the session the next turn opens.
            app.typeKey("k", modifierFlags: .command)
            app.typeText("detach")
            app.descendants(matching: .any)["palette.detach"].firstMatch.tap()
            XCTAssertTrue(header(app, log).waitForNonExistence(timeout: 10), "Detach left \(log)'s card")
        }
    }

    /// Lhûn in a window of its own, with Windowed Apps chosen in Settings, in landscape and then in portrait,
    /// with omp and a session split off it with ⌘D side by side. The window starts out filling the screen, and
    /// its corner handle is dragged to each pose in turn; a simulator does not tile windows with
    /// Control-Globe-Left, so the corner sizes them everywhere. At each pose the terminals fit their cards, the
    /// strip's buttons and the cards' headers lie inside the window, the host chip keeps the width it has
    /// while the window fills the screen, beside the inbox's glyph that tools/scenes.sh's rung bell brings,
    /// the open session's pill lies whole where the strip's pills scroll, there and filling the screen, the
    /// focused card's glyphs lie in one row inside its header beside its name, and the open palette lies
    /// inside the window and ends above the on-screen keyboard. All of that is the app's own measure, from the
    /// probe: XCTest's frames for a window short of the screen mix the window's points with the screen's.
    /// tools/scenes.sh photographs each pose as window-<pose>-<turn> and the palette over it as
    /// window-<pose>-palette-<turn>; each pose's sizes go to the test's log. The window fills the screen again
    /// before each turn. Afterwards, pass or fail, tools/scenes.sh puts the iPad back with testFullScreen.
    @MainActor
    func testWindows() throws {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["SCENES_PREFIX"], "run this test through tools/scenes.sh")
        // Split Right names the session it opens after the one it splits, with the first free number.
        let (omp, split) = ("\(prefix)-omp", "\(prefix)-omp-2")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        // The strip is what the windows are checked for; the sidebar layout, where he picked it, replaces it
        // in a window as wide as the screen held sideways.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-shares", "{}", "-probe", "YES",
                               "-layout", "tabs"]
        try multitasking("Windowed Apps")
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")

        for (orientation, turn) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            XCUIDevice.shared.orientation = orientation
            fill(app, springboard)
            try open(app, omp)
            if !header(app, split).exists {
                // Split Right, which the header's glyph and the palette also do: a new session beside omp's card.
                app.typeKey("d", modifierFlags: .command)
                XCTAssertTrue(header(app, split).waitForExistence(timeout: 30), "⌘D opened no card for \(split) beside \(omp)")
                XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(split) never attached")
                // The new card's terminal takes the keyboard, which would cover the corner handle the first pose drags.
                keyboardDown(app)
            }
            // The rung bell's session puts the inbox's glyph in the strip, which leaves the host chip the least
            // room it gets; with the window filling the screen, the chip has all it wants.
            XCTAssertTrue(app.buttons["inbox"].waitForExistence(timeout: 30), "\(turn): the strip shows no inbox glyph")
            let (_, roomy) = settle(probe, "\(turn), filling the screen")
            let host = try XCTUnwrap(roomy.frames["host"], "\(turn): the probe never placed the host chip").width
            assertOpenPillWhole(roomy, "\(turn), filling the screen")
            let screen = screenSize(springboard)
            var smallest = CGSize.zero
            for (pose, share) in Self.poses {
                let point = "\(pose) \(turn)"
                let window = app.windows.firstMatch
                let frame: CGRect
                if let share {
                    frame = resize(window, springboard, toWidth: screen.width * share, on: screen)
                    let wanted = CGSize(width: max(screen.width * share, smallest.width), height: screen.height)
                    XCTAssertTrue(
                        abs(frame.width - wanted.width) <= 20 && abs(frame.height - wanted.height) <= 20,
                        "\(point): the corner's drag left the window at \(frame), not \(wanted) on a \(screen) screen"
                    )
                } else {
                    frame = resize(window, springboard, cornerTo: CGPoint(x: 40, y: 40))
                    smallest = frame.size
                    XCTAssertTrue(
                        frame.width < screen.width && frame.height < screen.height,
                        "\(point): the corner's drag left the window at \(frame), filling the \(screen) screen"
                    )
                }
                keyboardDown(app)
                let (grids, chrome) = settle(probe, point)
                XCTContext.runActivity(named: "\(point): window \(frame) on a \(screen) screen; \(grids); \(chrome)") { _ in }
                XCTAssertEqual(grids.filter { $0.fit != "ok" }, [], "\(point): a terminal does not fit its card")
                XCTAssertEqual(grids.count, 2, "\(point): two terminals should be on screen")
                assertInside(chrome, ["host", "palette", "new-session", "card.mac.\(omp)", "card.mac.\(split)"], point)
                assertGlyphsBesideTheName(chrome, point)
                assertOpenPillWhole(chrome, point)
                XCTAssertEqual(chrome.frames["host"]?.width ?? 0, host, accuracy: 0.5, "\(point): the host chip is cut short")
                keep("window-\(pose)-\(turn)")

                app.typeKey("k", modifierFlags: .command)
                XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 10), "\(point): ⌘K opened no palette")
                #if targetEnvironment(simulator)
                // The palette's field brings up the on-screen keyboard, as on an iPad without a hardware keyboard.
                XCTAssertTrue(OnScreenKeyboard(app).up(within: 10), "\(point): the on-screen keyboard never came up for the palette")
                #endif
                let (_, opened) = settle(probe, "\(point), palette") { $0.frames["palette.query.card"] != nil }
                XCTContext.runActivity(named: "\(point), palette: \(opened)") { _ in }
                assertInside(opened, ["palette.query.card"], "\(point), palette")
                assertAboveTheKeyboard(opened, "palette.query.card", "\(point), palette")
                XCTAssertEqual(opened.frames["host"]?.width ?? 0, host, accuracy: 0.5, "\(point), palette: the host chip is cut short")
                keep("window-\(pose)-palette-\(turn)")
                app.typeKey("k", modifierFlags: .command)
                XCTAssertTrue(app.textFields["palette.query"].waitForNonExistence(timeout: 10), "\(point): ⌘K left the palette open")
                // The terminal takes the keyboard back as the palette closes, and the keyboard would cover the
                // corner handle the next pose drags.
                keyboardDown(app)
            }
        }
    }

    /// Puts the iPad back the way every other test expects it, after testWindows, pass or fail: tools/scenes.sh
    /// runs this in the same hold of the destination's lock. Lhûn's window fills the screen, then Full Screen
    /// Apps is chosen in Settings, and Lhûn comes back filling the screen, which tools/scenes.sh photographs as
    /// full-screen. The window fills the screen first because the system keeps its size for the app's next
    /// launch, under Windowed Apps.
    @MainActor
    func testFullScreen() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-shares", "{}"]
        app.launch()
        fill(app, springboard)
        try multitasking("Full Screen Apps")
        app.activate()
        let window = app.windows.firstMatch
        let screen = screenSize(springboard)
        XCTAssertTrue(
            within(10) { window.frame.width >= screen.width - 1 && window.frame.height >= screen.height - 1 },
            "with Full Screen Apps chosen, Lhûn's window stayed at \(window.frame) on the \(screen) screen"
        )
        keep("full-screen")
    }

    /// Opens the session from its pill, waits for it to attach, and puts the keyboard down.
    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        keyboardDown(app)
        let pill = onStrip(app, name)
        pill.tap()
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        keyboardDown(app)
        sleep(2)  // the terminal has drawn the session's screen at its size
    }

    /// Drags the session's pill onto the cards at `point`, a share of the window's width and height. A drag
    /// begins only after a press of half a second.
    @MainActor
    private func drop(_ app: XCUIApplication, _ name: String, at point: CGVector) {
        keyboardDown(app)
        let pill = onStrip(app, name)
        let target = app.windows.firstMatch.coordinate(withNormalizedOffset: point)
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 1)
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["card.mac.\(name)"].firstMatch
    }

    /// Chooses `choice` among Settings' Multitasking & Gestures options, Full Screen Apps, Windowed Apps and
    /// Stage Manager. Each option is a button named for it, marked selected while it is the chosen one.
    @MainActor
    private func multitasking(_ choice: String) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let row = settings.staticTexts["Multitasking & Gestures"].firstMatch
        guard row.waitForExistence(timeout: 10) else {
            add(XCTAttachment(string: settings.debugDescription))
            throw Failure(errorDescription: "Settings shows no Multitasking & Gestures")
        }
        row.tap()
        let options = [("Full Screen Apps", "fullScreenApps"), ("Windowed Apps", "windowedApps"), ("Stage Manager", "stageManager")]
            .map { label, key in (label, settings.buttons["com.apple.settings.multitaskingAndGestures.\(key)"].firstMatch) }
        guard options.allSatisfy({ $0.1.waitForExistence(timeout: 10) }) else {
            add(XCTAttachment(string: settings.debugDescription))
            throw Failure(errorDescription: "Multitasking & Gestures lacks one of \(options.map(\.0))")
        }
        guard let chosen = options.first(where: { $0.1.isSelected })?.0,
              let wanted = options.first(where: { $0.0 == choice })?.1
        else {
            add(XCTAttachment(string: settings.debugDescription))
            throw Failure(errorDescription: "Multitasking & Gestures marks none of its options chosen, or has no \(choice)")
        }
        if chosen != choice {
            wanted.tap()
            guard within(10, { wanted.isSelected }) else {
                add(XCTAttachment(string: settings.debugDescription))
                throw Failure(errorDescription: "\(choice) never became the chosen option")
            }
        }
        settings.terminate()
    }

    /// Makes the window fill the screen, as it did before the test: once a turn has had time to finish, a
    /// window short of the screen has its corner handle dragged past the screen's far corner, where the
    /// system stops it.
    @MainActor
    private func fill(_ app: XCUIApplication, _ springboard: XCUIApplication) {
        let window = app.windows.firstMatch
        let screen = screenSize(springboard)
        let fills = { window.frame.width >= screen.width - 1 && window.frame.height >= screen.height - 1 }
        guard window.exists, !within(5, fills) else { return }
        // The terminal may have the keyboard, which covers the corner handle of a window as tall as the screen.
        keyboardDown(app)
        let frame = resize(window, springboard, cornerTo: CGPoint(x: screen.width + 40, y: screen.height + 40))
        XCTAssertTrue(fills(), "the window never filled the \(screen) screen; it stayed at \(frame)")
    }

    /// The screen's size the way the window's frame measures it: SpringBoard's frame keeps the upright
    /// screen's size as the iPad turns, so in landscape the long side is the width.
    @MainActor
    private func screenSize(_ springboard: XCUIApplication) -> CGSize {
        let upright = springboard.frame.size
        let (long, short) = (max(upright.width, upright.height), min(upright.width, upright.height))
        return XCUIDevice.shared.orientation.isLandscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// Drags the window's corner handle, at its bottom right, to `corner`, a point on the screen, and returns
    /// the window's frame once it has stopped changing. The system holds the window between its smallest and
    /// largest sizes and on the screen. A window shrunk from filling the screen comes to rest centered across
    /// it and stays centered as it grows, widening on both sides as its corner moves; a corner dragged past
    /// the screen's bottom gives it the screen's full height.
    @MainActor
    private func resize(_ window: XCUIElement, _ springboard: XCUIApplication, cornerTo corner: CGPoint) -> CGRect {
        let frame = window.frame
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.maxX - 10, dy: frame.maxY - 10)).press(
            forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: corner.x - 10, dy: corner.y - 10)),
            withVelocity: .slow, thenHoldForDuration: 0.5
        )
        var last = window.frame
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = window.frame
            if now == last { return now }
            last = now
        }
        XCTFail("the window never stopped changing size; it was last at \(last)")
        return last
    }

    /// Sizes the window with its corner handle to `width` points wide and the screen's full height, and
    /// returns its frame. A centered window widens on both sides, so its corner goes half as far; a width
    /// still more than 20 points off takes a second drag, scaled by what the first one did.
    @MainActor
    private func resize(
        _ window: XCUIElement, _ springboard: XCUIApplication, toWidth width: CGFloat, on screen: CGSize
    ) -> CGRect {
        let start = window.frame
        let sides: CGFloat = abs(start.midX - screen.width / 2) < 2 ? 2 : 1
        let moved = (width - start.width) / sides
        let first = resize(window, springboard, cornerTo: CGPoint(x: start.maxX + moved, y: screen.height + 40))
        let grew = first.width - start.width
        guard abs(first.width - width) > 20, abs(grew) > 1, abs(moved) > 1 else { return first }
        let corner = CGPoint(x: first.maxX + (width - first.width) * moved / grew, y: screen.height + 40)
        return resize(window, springboard, cornerTo: corner)
    }

    /// Each named piece of chrome lies inside the window, by the app's own measure.
    @MainActor
    private func assertInside(_ chrome: Chrome, _ names: [String], _ point: String) {
        for name in names {
            guard let frame = chrome.frames[name] else {
                XCTFail("\(point): the probe never placed \(name)")
                continue
            }
            XCTAssertTrue(
                chrome.window.insetBy(dx: -1, dy: -1).contains(frame),
                "\(point): \(name) at \(frame) leaves the window, \(chrome.window.size)"
            )
        }
    }

    /// The named piece of chrome ends above the on-screen keyboard where the keyboard reaches into the window,
    /// by the app's own measure. A keyboard below the window, or none, leaves nothing to check.
    @MainActor
    private func assertAboveTheKeyboard(_ chrome: Chrome, _ name: String, _ point: String) {
        guard let frame = chrome.frames[name], let keyboard = chrome.frames["keyboard"], keyboard.minY < chrome.window.maxY
        else { return }
        XCTAssertLessThanOrEqual(
            frame.maxY, keyboard.minY + 1, "\(point): \(name) at \(frame) runs under the keyboard, whose top is at \(keyboard.minY)"
        )
    }

    /// The focused card's glyphs lie inside its header, after its name, which keeps at least 40 points, by
    /// the app's own measure. The test's sessions' names are longer than that.
    @MainActor
    private func assertGlyphsBesideTheName(_ chrome: Chrome, _ point: String) {
        let card = "card.mac.\(chrome.selection)"
        guard let header = chrome.frames[card], let glyphs = chrome.frames["\(card).glyphs"], let name = chrome.frames["\(card).name"]
        else {
            XCTFail("\(point): the probe never placed the focused card's header, glyphs and name; \(chrome)")
            return
        }
        XCTAssertTrue(header.insetBy(dx: -1, dy: -1).contains(glyphs), "\(point): the glyphs at \(glyphs) leave \(card)'s header at \(header)")
        XCTAssertTrue(
            name.width >= 40 && name.maxX <= glyphs.minX + 1,
            "\(point): \(card)'s name at \(name) has no room beside its glyphs at \(glyphs)"
        )
    }

    /// The open session's pill lies whole where the strip's pills scroll, by the app's own measure: the strip
    /// scrolls it into view, and no pill is wider than that.
    @MainActor
    private func assertOpenPillWhole(_ chrome: Chrome, _ point: String) {
        let name = "pill.mac.\(chrome.selection)"
        guard let pills = chrome.frames["pills"], let pill = chrome.frames[name] else {
            XCTFail("\(point): the probe never placed the strip's pills and \(name); \(chrome)")
            return
        }
        XCTAssertTrue(pills.insetBy(dx: -0.5, dy: -0.5).contains(pill), "\(point): \(name) at \(pill) runs past the strip's pills at \(pills)")
    }

    /// Waits until two probe samples in a row report the same terminals on screen and the same chrome, which
    /// `ready` accepts, then returns them.
    @MainActor
    private func settle(
        _ probe: XCUIElement, _ point: String, until ready: (Chrome) -> Bool = { _ in true }
    ) -> (grids: [Grid], chrome: Chrome) {
        let deadline = Date.now.addingTimeInterval(40)
        var previous: (t: Double, grids: [Grid], chrome: Chrome)?
        while Date.now < deadline {
            if let sample = probeSample(probe), sample.t != previous?.t {
                if let previous, previous.grids == sample.grids, previous.chrome == sample.chrome, !sample.grids.isEmpty,
                   ready(sample.chrome) {
                    return (sample.grids, sample.chrome)
                }
                previous = sample
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("\(point): the probe never settled; last \(previous.map { "\($0.grids); \($0.chrome)" } ?? "nothing")")
        return (previous?.grids ?? [], previous?.chrome ?? Chrome(window: .null, frames: [:], selection: ""))
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Puts the on-screen keyboard down if it is up, or comes up within 3 seconds.
    @MainActor
    private func keyboardDown(_ app: XCUIApplication) {
        OnScreenKeyboard(app).putDown(ifUpWithin: 3)
    }

    /// Whether `condition` holds within `seconds`.
    @MainActor
    private func within(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    /// Has tools/scenes.sh photograph the screen as `name`.png, and holds still until it has: the test asks
    /// with an empty file, take-scenes-<name>, in its runner's Documents, and the script answers with
    /// taken-scenes-<name>.
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-scenes-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-scenes-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the screenshot \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/scenes.sh never photographed \(name)")
    }
}
