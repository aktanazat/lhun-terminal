import XCTest

/// The sidebar layout, its folding groups, the hover picture and the hover close, through tools/sidebar.sh,
/// which puts sessions named lhun-test-sidebar-* on both hosts first, in folders, one on each having rung
/// its bell, and two on the Mac standing in for Claude Code, one blocked on a question and one at work, and
/// photographs each scene a test holds still for, in dark and then in light.
/// Most tests pick the sidebar layout with a launch argument, which the app does not keep, and start with
/// every group open; the test that picks it in the palette puts the pills back, so the next run on the
/// shared iPad still gets them.
final class SidebarShots: XCTestCase {
    private static let prefix = "lhun-test-sidebar"
    private static let sidebarLayout = ["-layout", "sidebar", "-sidebar", "YES", "-sidebarFolded", "()"]

    override func setUp() {
        continueAfterFailure = false
    }

    /// In the sidebar layout, held sideways, the sidebar stands where the strip was: each host's sessions
    /// under its name and then their folder's. A row opens its session, the server's too, and sits raised
    /// while open. The sidebar's glyph hides it, leaving its bar above the cards, and brings it back, and
    /// each way the terminal is sized once, not once per frame of the slide. The bar's eye shows every
    /// session at a glance and puts them away again. Typing in the filter narrows the list on both hosts.
    /// A session that rang its bell needs him.
    @MainActor
    func testSidebarListsFiltersAndOpens() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .dark }
        let app = launch(Self.sidebarLayout)
        let probe = element(app, "probe")
        let sidebar = element(app, "sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the sidebar layout held sideways showed no sidebar")
        XCTAssertFalse(element(app, "host").exists, "the strip stayed beside the sidebar")
        let shell = "\(Self.prefix)-shell"
        try openRow(app, shell, on: "mac")
        XCTAssertTrue(holds(app.buttons["sidebar.mac.\(shell)"], "selected == true"), "the open session's row is not raised")

        try photograph(app, "sidebar") {
            try filter(app, Self.prefix)
            keyboardDown(app)
        }
        // tools/sidebar.sh starts the shell, vim and logs sessions in its checkout, and names its folder.
        let checkout = try XCTUnwrap(ProcessInfo.processInfo.environment["SIDEBAR_CHECKOUT"], "tools/sidebar.sh names no checkout")
        for (host, folder) in [("mac", "claude"), ("mac", checkout), ("mac", "work"), ("server", "~")] {
            XCTAssertTrue(element(app, "sidebar.folder.\(host).\(folder)").exists, "\(host) shows no \(folder) folder")
        }
        XCTAssertTrue(element(app, "sidebar.host.server").exists, "the server is not listed")
        // A session whose program reports what it is doing shows that, in its own words, under its name.
        for (session, words) in [("ask", "Do you prefer red or blue?"), ("agent", "Running the test suite")] {
            let row = app.buttons["sidebar.mac.\(Self.prefix)-\(session)"]
            XCTAssertTrue(holds(row, "label CONTAINS '\(words)'"), "the \(session) row says “\(row.label)”, not its program's words")
        }

        // The keyboard is down, so the only change in size is the sidebar's.
        let toggle = app.buttons["sidebar-toggle"]
        let beside = try settled(probe, shell, "beside the sidebar")
        toggle.tap()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), "the glyph did not hide the sidebar")
        XCTAssertTrue(toggle.exists, "the sidebar's bar went with it")
        XCTAssertFalse(toggle.isSelected, "the glyph says the sidebar is still out")
        let full = try settled(probe, shell, "without the sidebar") { $0.cols > beside.cols }
        XCTAssertEqual(full.resizes - beside.resizes, 1, "hiding the sidebar sized the terminal more than once")
        try photograph(app, "hidden") { keyboardDown(app) }
        let hidden = try settled(probe, shell, "without the sidebar, the keyboard down")
        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the glyph did not bring the sidebar back")
        let back = try settled(probe, shell, "beside the sidebar again") { $0.cols < hidden.cols }
        XCTAssertEqual(back.resizes - hidden.resizes, 1, "showing the sidebar sized the terminal more than once")
        XCTAssertEqual(back.cols, beside.cols, "the terminal came back to another width")
        XCTAssertEqual(back.rows, beside.rows, "the terminal came back to another height")

        let eye = app.buttons["peek-toggle"]
        eye.tap()
        let grid = element(app, "peek.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "the eye showed no sessions at a glance")
        XCTAssertTrue(eye.isSelected, "the eye is not lit while the sessions show")
        eye.tap()
        XCTAssertTrue(grid.waitForNonExistence(timeout: 5), "the eye left the sessions showing")

        try photograph(app, "filter") {
            try filter(app, "python")
            keyboardDown(app)
        }
        listed(app, "python", shows: ["mac.\(Self.prefix)-python", "server.\(Self.prefix)-python"],
               hides: ["mac.\(Self.prefix)-vim", "server.\(Self.prefix)-htop"])
        try filter(app, "sidebar-htop")
        // The filter matches loosely, as the palette does, so a long folder can lend a row the letters: the
        // Mac's python sits in /private/var/tmp, which spells out "htop" after its name's h.
        listed(app, "sidebar-htop", shows: ["server.\(Self.prefix)-htop"],
               hides: ["mac.\(Self.prefix)-vim", "server.\(Self.prefix)-python"])

        try filter(app, "sidebar-bell")
        XCTAssertTrue(element(app, "sidebar.folder.server.tmp").waitForExistence(timeout: 10), "the server shows no tmp folder")
        for host in ["mac", "server"] {
            let bell = app.buttons["sidebar.\(host).\(Self.prefix)-bell"]
            XCTAssertTrue(holds(bell, "value == 'needs you'"), "\(host)'s session that rang its bell does not need him")
            XCTAssertTrue(bell.label.contains("Needs you"), "\(host)'s session that rang its bell says “\(bell.label)”")
        }

        try filter(app, "python")
        let python = "\(Self.prefix)-python"
        let row = app.buttons["sidebar.server.\(python)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the server's python session is not listed")
        row.tap()
        attached(app, python)
        XCTAssertTrue(element(app, "card.server.\(python)").waitForExistence(timeout: 10), "the server's python session did not open")
        XCTAssertTrue(holds(row, "selected == true"), "the open session's row is not raised")
    }

    /// A host's or a folder's header folds its rows away and opens them again. Folded, it shows the dot, and
    /// its value says how many sessions it holds and that one of them needs him: each host's session that
    /// rang its bell does. The filter finds rows inside folded groups, and the folds are back once it
    /// empties. The app keeps them, host by host and folder by folder. A fold slides, and with Reduce
    /// Motion on it happens at once. The headers this folds sit at the top of the list, so each is drawn
    /// however many sessions the hosts hold.
    @MainActor
    func testGroupsFold() throws {
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.appearance = .dark
            self.switchReduceMotion(false)
        }
        switchReduceMotion(false)
        let app = launch(Self.sidebarLayout)
        let probe = element(app, "probe")
        let shell = "\(Self.prefix)-shell"
        try openRow(app, shell, on: "mac")
        app.buttons["sidebar.filter.clear"].tap()
        keyboardDown(app)

        let mac = element(app, "sidebar.host.mac")
        let server = element(app, "sidebar.host.server")
        let tmp = element(app, "sidebar.folder.server.tmp")
        let macPython = app.buttons["sidebar.mac.\(Self.prefix)-python"]
        let serverBell = app.buttons["sidebar.server.\(Self.prefix)-bell"]
        let notes = app.buttons["sidebar.server.\(Self.prefix)-notes"]
        XCTAssertTrue(mac.waitForExistence(timeout: 10), "the sidebar lists no Mac")
        XCTAssertTrue(holds(mac, "value == 'open'"), "the Mac's group did not start open: “\(mac.value ?? "")”")
        XCTAssertEqual(folds(probe, reach: Folds(animated: 0, still: 0)), Folds(animated: 0, still: 0),
                       "something folded before a header was tapped")

        mac.tap()
        XCTAssertTrue(holds(mac, "value BEGINSWITH 'folded, ' AND value ENDSWITH ' sessions, needs you'"),
                      "the folded Mac says “\(mac.value ?? "")”, not its count and that a session needs him")
        XCTAssertTrue(within(5) { !macRows(app).exists }, "folding the Mac left its rows")
        XCTAssertFalse(element(app, "sidebar.folder.mac.work").exists, "folding the Mac left its folders")
        XCTAssertEqual(folds(probe, reach: Folds(animated: 1, still: 0)), Folds(animated: 1, still: 0),
                       "with Reduce Motion off, the fold did not slide")

        XCTAssertTrue(server.waitForExistence(timeout: 5), "the server is not listed")
        XCTAssertTrue(tmp.waitForExistence(timeout: 5), "the server shows no tmp folder")
        XCTAssertTrue(serverBell.waitForExistence(timeout: 10), "the server's bell session is not listed")
        XCTAssertTrue(holds(serverBell, "value == 'needs you'"), "the server's session that rang its bell does not need him")
        tmp.tap()
        XCTAssertTrue(serverBell.waitForNonExistence(timeout: 5), "folding tmp left its bell row")
        XCTAssertFalse(notes.exists, "folding tmp left its notes row")
        XCTAssertTrue(holds(tmp, "value == 'folded, 2 sessions, needs you'"), "the folded tmp says “\(tmp.value ?? "")”")
        XCTAssertTrue(holds(server, "value == 'open'"), "folding tmp folded the server")
        try photograph(app, "fold") { keyboardDown(app) }

        try filter(app, "python")
        listed(app, "python", shows: ["mac.\(Self.prefix)-python", "server.\(Self.prefix)-python"], hides: [])
        try filter(app, "sidebar-bell")
        listed(app, "sidebar-bell", shows: ["mac.\(Self.prefix)-bell", "server.\(Self.prefix)-bell"], hides: [])
        app.buttons["sidebar.filter.clear"].tap()
        XCTAssertTrue(serverBell.waitForNonExistence(timeout: 5), "tmp did not fold again once the filter emptied")
        XCTAssertFalse(macPython.exists, "the Mac did not fold again once the filter emptied")
        XCTAssertTrue(holds(mac, "value BEGINSWITH 'folded'"), "the Mac says “\(mac.value ?? "")” once the filter emptied")

        app.terminate()
        switchReduceMotion(true)
        relaunch(app, ["-layout", "sidebar", "-sidebar", "YES"])
        XCTAssertTrue(holds(mac, "value BEGINSWITH 'folded'"), "the Mac came back open with the app")
        XCTAssertTrue(holds(tmp, "value BEGINSWITH 'folded'"), "tmp came back open with the app")
        XCTAssertTrue(holds(server, "value == 'open'"), "the server came back folded with the app")
        XCTAssertFalse(serverBell.exists, "tmp's rows came back with the app")

        XCTAssertTrue(waitFor(probe, "reduceMotion") { $0 == 1 }, "Lhûn never saw Reduce Motion on")
        tmp.tap()
        XCTAssertTrue(serverBell.waitForExistence(timeout: 5), "opening tmp brought back no bell row")
        XCTAssertTrue(holds(tmp, "value == 'open'"), "the opened tmp says “\(tmp.value ?? "")”")
        // The counts start again with the app.
        XCTAssertEqual(folds(probe, reach: Folds(animated: 0, still: 1)), Folds(animated: 0, still: 1),
                       "with Reduce Motion on, the fold slid")
        mac.tap()
        XCTAssertTrue(holds(mac, "value == 'open'"), "the opened Mac says “\(mac.value ?? "")”")
        XCTAssertTrue(macRows(app).waitForExistence(timeout: 5), "opening the Mac brought back none of its rows")
    }

    /// With a trackpad's pointer on a pill, held here or not, a small × shows on the pill, as on a Safari
    /// tab, beside the session's picture. A pill opened with a tap, as a finger does, shows no ×. Tapping
    /// the × ends the session on the Mac: its card closes and its pill leaves the strip.
    @MainActor
    func testHoverClosesAPill() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .dark }
        let python = "\(Self.prefix)-python"
        let shell = "\(Self.prefix)-shell"
        let app = launch(["-layout", "tabs", "-probePointer", "mac.\(python)"])
        let probe = element(app, "probe")
        let close = app.buttons["session.close.mac.\(python)"]
        let pill = app.buttons["session.mac.\(python)"]
        let picture = element(app, "hover")
        let card = element(app, "card.mac.\(python)")
        try open(app, shell)
        try photograph(app, "hover-close") {
            keyboardDown(app)
            pointer(.rest)
            XCTAssertTrue(picture.waitForExistence(timeout: 5), "the pointer never reached the pill")
            XCTAssertTrue(close.waitForExistence(timeout: 5), "the pointer on a pill Lhûn does not hold showed no ×")
        }
        pointer(.leave)
        XCTAssertTrue(picture.waitForNonExistence(timeout: 5), "the picture stayed after the pointer left the pill")
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "the × stayed after the pointer left the pill")

        try open(app, python)
        keyboardDown(app)
        XCTAssertFalse(close.waitForExistence(timeout: 2), "a tap on the pill showed the ×")
        XCTAssertTrue(waitFor(probe, "terminals") { $0 == 2 }, "Lhûn does not hold both sessions")
        pointer(.rest)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the pointer on the open session's pill showed no ×")
        XCTAssertTrue(pill.frame.contains(CGPoint(x: close.frame.midX, y: close.frame.midY)), "the × is not on its pill")
        close.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "the × left the session's card")
        XCTAssertTrue(pill.waitForNonExistence(timeout: 10), "the × left the session running on the Mac")
        XCTAssertTrue(waitFor(probe, "terminals") { $0 == 1 }, "the × did not let go of the session")
    }

    /// The layout is a setting: the palette's Layout row moves between the pills and the sidebar at once,
    /// and the app keeps the choice, as it keeps whether the sidebar is out. ⌃⌘S hides and shows it as the
    /// glyph does, without reaching the session as a Control-S. Held upright, the sidebar layout shows the
    /// pills and ⌃⌘S does nothing, though the app got the key; turned sideways again, the sidebar comes back.
    @MainActor
    func testLayoutIsASettingAndIsKept() throws {
        let app = launch()
        let original = XCUIDevice.shared.orientation
        let probe = element(app, "probe")
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.appearance = .dark
            XCUIDevice.shared.orientation = original
            self.leaveTabs(app, probe)
        }
        let shell = "\(Self.prefix)-shell"
        let pill = app.buttons["session.mac.\(shell)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the pills were not the layout before the run")
        try open(app, shell)
        let sidebar = element(app, "sidebar")
        let toggle = app.buttons["sidebar-toggle"]
        try palette(app, probe, "layout", run: "layout")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Layout row did not switch to the sidebar")
        XCTAssertFalse(pill.exists, "the pills stayed in the sidebar layout")
        if !sidebar.waitForExistence(timeout: 3) { toggle.tap() }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the glyph showed no sidebar")
        // The keys go to the terminal, where a Control-S would reach the session.
        app.textViews["terminal"].firstMatch.tap()

        let sent = try number(probe, "sentCount")
        try typeCommand("s", [.command, .control], in: app, probe: probe)
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), "⌃⌘S did not hide the sidebar")
        sleep(2)
        XCTAssertEqual(try keys(probe, since: sent), "", "⌃⌘S reached the session")
        app.terminate()
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the sidebar layout did not come back with the app")
        XCTAssertFalse(sidebar.waitForExistence(timeout: 3), "the hidden sidebar came back with the app")
        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the glyph showed no sidebar")
        try openRow(app, shell, on: "mac")
        try typeCommand("s", [.command, .control], in: app, probe: probe)
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), "⌃⌘S did not hide the sidebar")
        try typeCommand("s", [.command, .control], in: app, probe: probe)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "⌃⌘S did not show the sidebar")
        app.terminate()
        app.launch()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), "the sidebar did not come back with the app")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 10), "the sidebar stayed with the iPad upright")
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "held upright, the sidebar layout showed no pills")
        XCTAssertFalse(toggle.exists, "the sidebar's glyph stayed with the iPad upright")
        try open(app, shell)
        let sentUpright = try number(probe, "sentCount")
        try typeCommand("s", [.command, .control], in: app, probe: probe)
        XCTAssertFalse(sidebar.waitForExistence(timeout: 3), "⌃⌘S showed the sidebar with the iPad upright")
        XCTAssertEqual(try keys(probe, since: sentUpright), "", "⌃⌘S reached the session with the iPad upright")
        try photograph(app, "portrait") { keyboardDown(app) }
        XCUIDevice.shared.orientation = original
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the sidebar did not come back with the iPad sideways")

        try palette(app, probe, "layout", run: "layout")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the Layout row did not switch back to the pills")
        XCTAssertFalse(toggle.exists, "the sidebar's glyph stayed with the pills")
        app.terminate()
        app.launch()
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the pills did not come back with the app")
    }

    @MainActor
    func testLayoutSwitchIsDirect() {
        let app = launch(["-layout", "tabs"])
        let toggle = app.buttons["layout-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the tabs offer no direct sidebar switch")
        let tabs = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        tabs.name = "rex-layout-tabs"
        tabs.lifetime = .keepAlways
        add(tabs)
        toggle.tap()
        XCTAssertTrue(element(app, "sidebar").waitForExistence(timeout: 5), "the switch did not show the sidebar")
        let sidebar = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sidebar.name = "rex-layout-sidebar"
        sidebar.lifetime = .keepAlways
        add(sidebar)
        app.buttons["layout-toggle"].tap()
        XCTAssertTrue(element(app, "strip").waitForExistence(timeout: 5), "the switch did not restore the tabs")
    }

    @MainActor
    func testTabsOfferTouchActivityForFocusedTerminal() throws {
        try activityGlance(layout: "tabs")
    }

    @MainActor
    func testSidebarOffersTouchActivityForFocusedTerminal() throws {
        try activityGlance(layout: "sidebar")
    }

    /// Resting the pointer on a sidebar row shows a picture of its session's screen right of the row, and
    /// moving off takes the picture away and lets it go; a pill does the same, the picture below it.
    /// Nothing is captured until the pointer rests. XCTest's hover reaches no SwiftUI hover handler on the
    /// simulator or the iPad, so the probe moves the pointer (`pointer(_:)`), through the same handler a
    /// trackpad drives.
    @MainActor
    func testHoverShowsAPictureOfTheSession() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .dark }
        let htop = "\(Self.prefix)-htop"
        let app = launch(Self.sidebarLayout + ["-probePointer", "server.\(htop)"])
        let probe = element(app, "probe")
        let shell = "\(Self.prefix)-shell"
        try openRow(app, shell, on: "mac")
        XCTAssertEqual(measured(probe, "hover")?["captures"], 0, "a screen was captured before the pointer rested")

        try filter(app, Self.prefix)
        keyboardDown(app)
        let row = app.buttons["sidebar.server.\(htop)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the server's htop session is not listed")
        let more = app.buttons["sidebar.more.server.\(htop)"]
        pointer(.rest)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the row offers no activity button")
        let picture = element(app, "hover")
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "resting on a row showed no picture")
        XCTAssertEqual(picture.value as? String, "server.\(htop)", "the picture is of another session")
        XCTAssertGreaterThan(picture.frame.minX, row.frame.maxX, "the picture is not right of its row")
        let shown = measured(probe, "hover") { ($0["pixels"] ?? 0) > 0 }
        XCTAssertEqual(shown?["captures"], 1, "one rest took \(shown?["captures"] ?? 0) captures")
        pointer(.leave)
        XCTAssertTrue(picture.waitForNonExistence(timeout: 5), "the picture stayed after the pointer left the row")
        XCTAssertNotNil(measured(probe, "hover") { $0["pixels"] == nil }, "the picture was kept after it went")
        XCTAssertTrue(more.exists, "leaving the row hid its touch activity button")
        // Each rest paints the picture in the look of its moment.
        try photograph(app, "hover") {
            keyboardDown(app)
            pointer(.leave)
            XCTAssertTrue(picture.waitForNonExistence(timeout: 5), "the picture stayed after the pointer left the row")
            pointer(.rest)
            XCTAssertTrue(picture.waitForExistence(timeout: 5), "resting on a row showed no picture")
        }

        app.terminate()
        let python = "\(Self.prefix)-python"
        relaunch(app, ["-layout", "tabs", "-probePointer", "mac.\(python)"])
        try open(app, shell)
        keyboardDown(app)
        let pill = app.buttons["session.mac.\(python)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the Mac's python session has no pill")
        pointer(.rest)
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "resting on a pill showed no picture")
        XCTAssertEqual(picture.value as? String, "mac.\(python)", "the picture is of another session")
        XCTAssertGreaterThan(picture.frame.minY, pill.frame.maxY, "the picture is not below its pill")
        XCTAssertEqual(measured(probe, "hover") { ($0["pixels"] ?? 0) > 0 }?["captures"], 1, "a rest on a pill took no capture")
        pointer(.leave)
        XCTAssertTrue(picture.waitForNonExistence(timeout: 5), "the picture stayed after the pointer left the pill")
        XCTAssertNotNil(measured(probe, "hover") { $0["pixels"] == nil }, "the picture was kept after it went")
    }

    private enum Pointer: String {
        case rest
        case leave
    }

    /// Moves the probe's stand-in pointer onto the session `-probePointer` names, or off it.
    @MainActor
    private func pointer(_ move: Pointer) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.aktanazat.lhun.probe.pointer.\(move.rawValue)" as CFString), nil, nil, true
        )
    }

    // MARK: Helpers

    @MainActor
    private func activityGlance(layout: String) throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .dark }
        let app = launch(["-layout", layout, "-sidebar", "YES", "-sidebarFolded", "()"])
        let probe = element(app, "probe")
        let session = "\(Self.prefix)-ask"
        if layout == "sidebar" {
            try openRow(app, session, on: "mac")
        } else {
            try open(app, session)
        }
        keyboardDown(app)
        let before = try settled(probe, session, "before the activity glance")
        let card = element(app, "card.mac.\(session)")
        let frame = card.frame
        let moreID = layout == "sidebar" ? "sidebar.more.mac.\(session)" : "session.more.mac.\(session)"
        let more = app.buttons[moreID]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "activity needs a pointer before touch can reach it")
        XCTAssertGreaterThanOrEqual(more.frame.width, 44, "the activity button is too narrow to touch")
        XCTAssertGreaterThanOrEqual(more.frame.height, 44, "the activity button is too short to touch")
        more.tap()
        let panel = element(app, "tab.activity")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the activity button opened no terminal activity")
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'activity.row.' AND label CONTAINS %@", session)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the activity panel lists no focused terminal")
        XCTAssertTrue(holds(row, "label CONTAINS[cd] 'needs you'"), "the focused terminal lost its reported state")
        XCTAssertTrue(holds(row, "label CONTAINS 'Do you prefer red or blue?'"), "the focused terminal lost its program's message")
        XCTAssertTrue(holds(row, "label CONTAINS 'lhun-sidebar/claude'"), "the activity row lost its folder")
        XCTAssertTrue(row.isSelected, "the activity panel does not identify the focused terminal")
        XCTAssertEqual(try settled(probe, session, "during the activity glance"), before, "glancing at activity resized the terminal")
        XCTAssertEqual(card.frame, frame, "the activity panel moved the card")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "glancing at activity raised a keyboard")
        try photograph(app, "activity-\(layout)") {}
        app.buttons["tab.activity.close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "the close button left activity open")
        XCTAssertEqual(try settled(probe, session, "after the activity glance"), before, "closing activity resized the terminal")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "closing activity raised a keyboard")
    }

    /// One terminal as the probe reports it: its grid, and how many sizes it has sent tmux.
    private struct Fit: Equatable {
        let cols: Int
        let rows: Int
        let resizes: Int
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        // The sidebar stands only on an iPad held sideways, which a simulator is not until it is turned.
        let original = XCUIDevice.shared.orientation
        if ![.landscapeLeft, .landscapeRight].contains(original) {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = original }
        }
        let app = XCUIApplication()
        relaunch(app, arguments)
        return app
    }

    @MainActor
    private func relaunch(_ app: XCUIApplication, _ arguments: [String]) {
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"] + arguments
        app.launch()
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Puts `text` in the sidebar's filter in place of what was there.
    @MainActor
    private func filter(_ app: XCUIApplication, _ text: String) throws {
        let field = app.textFields["sidebar.filter"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no filter atop the sidebar")
        let clear = app.buttons["sidebar.filter.clear"]
        if clear.exists { clear.tap() }
        field.tap()
        field.typeText(text)
    }

    /// With `query` in the filter, the sidebar lists the rows `kept` and none of the rows `dropped`, each
    /// named "<host>.<session>". The filter keeps the list short enough that every row it keeps is drawn.
    @MainActor
    private func listed(_ app: XCUIApplication, _ query: String, shows kept: [String], hides dropped: [String]) {
        for row in kept {
            XCTAssertTrue(app.buttons["sidebar.\(row)"].waitForExistence(timeout: 10), "“\(query)” left out \(row)")
        }
        for row in dropped {
            XCTAssertFalse(app.buttons["sidebar.\(row)"].exists, "“\(query)” kept \(row)")
        }
    }

    /// Opens a session from its sidebar row, found by its whole name in the filter, and waits until it
    /// takes typing.
    @MainActor
    private func openRow(_ app: XCUIApplication, _ session: String, on host: String) throws {
        try filter(app, session)
        let row = app.buttons["sidebar.\(host).\(session)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(session) never showed in the sidebar; tools/sidebar.sh makes it")
        row.tap()
        attached(app, session)
        // The first key after launch can go astray; this one types nothing that matters, and the next key
        // waits out the keyboard swap it sets off.
        try typeSettled("l", .control, in: app, probe: element(app, "probe"))
    }

    /// Opens a session from its pill, brought into the strip, and waits until it takes typing.
    @MainActor
    private func open(_ app: XCUIApplication, _ session: String) throws {
        onStrip(app, session).tap()
        attached(app, session)
        try typeSettled("l", .control, in: app, probe: element(app, "probe"))
    }

    /// Any of the Mac's rows in the sidebar.
    @MainActor
    private func macRows(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.mac.'")).firstMatch
    }

    @MainActor
    private func attached(_ app: XCUIApplication, _ session: String) {
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(session) never attached")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "\(session) never took the keyboard")
        // Keys typed while the keyboard slides in are lost.
        sleep(1)
    }

    /// Runs the palette row `row`, found by typing `query`.
    @MainActor
    private func palette(_ app: XCUIApplication, _ probe: XCUIElement, _ query: String, run row: String) throws {
        try typeCommand("k", .command, in: app, probe: probe)
        let field = app.textFields["palette.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K opened no palette")
        field.typeText(query)
        let button = app.buttons["palette.\(row)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the palette has no \(row) row")
        button.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the palette stayed open after its \(row) row ran")
    }

    /// A top-level number in the probe's report.
    @MainActor
    private func number(_ probe: XCUIElement, _ key: String) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        return try XCTUnwrap((object?[key] as? NSNumber)?.intValue, "the probe reports no \(key)")
    }

    /// Whether the probe reports a top-level number `accept` takes within ten seconds; a yes or no counts as
    /// 1 or 0.
    @MainActor
    private func waitFor(_ probe: XCUIElement, _ key: String, until accept: (Int) -> Bool) -> Bool {
        within(10) {
            let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
            return ((object?[key] as? NSNumber)?.intValue).map(accept) ?? false
        }
    }

    /// The sidebar's folds since launch, as the probe counts them: those that slid, and those that happened
    /// at once.
    private struct Folds: Equatable {
        let animated: Int
        let still: Int
    }

    /// The probe's count of folds once it comes to `expected`, or the last count after ten seconds.
    @MainActor
    private func folds(_ probe: XCUIElement, reach expected: Folds) -> Folds? {
        var last: Folds?
        _ = measured(probe, "sidebarFolds") { counts in
            last = Folds(animated: counts["animated"] ?? 0, still: counts["still"] ?? 0)
            return last == expected
        }
        return last
    }

    /// What went out to the session since the probe had counted `before` bytes, as far as its last 256 go,
    /// in hex, leaving out the terminal's answers to tmux asking its size (CSI … t) and colors (OSC 10 and
    /// 11), which come whenever the terminal changes size, as it does when the sidebar shows or hides.
    @MainActor
    private func keys(_ probe: XCUIElement, since before: Int) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        let count = try XCTUnwrap((object?["sentCount"] as? NSNumber)?.intValue, "the probe reports no sentCount")
        let hex = Array((object?["sent"] as? String ?? "").utf8)
        let last = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
            UInt8(String(decoding: hex[$0...$0 + 1], as: UTF8.self), radix: 16)
        }
        let written = String(decoding: last.suffix(max(0, count - before)), as: UTF8.self)
        let keys = written.replacing(/\u{1B}\[[0-9;]*t|\u{1B}\][^\u{1B}\u{07}]*(\u{1B}\\|\u{07})/, with: "")
        return Array(keys.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// The terminal showing `session`, once two probe samples in a row agree on it and `accept` takes it.
    @MainActor
    private func settled(
        _ probe: XCUIElement, _ session: String, _ point: String, until accept: (Fit) -> Bool = { _ in true }
    ) throws -> Fit {
        let deadline = Date.now.addingTimeInterval(30)
        var previous: (t: Double, fit: Fit)?
        while Date.now < deadline {
            if let sample = fit(probe, session), sample.t != previous?.t {
                if let previous, previous.fit == sample.fit, accept(sample.fit) { return sample.fit }
                previous = sample
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return try XCTUnwrap(nil as Fit?, "\(point): the terminal never settled; last \(String(describing: previous?.fit))")
    }

    @MainActor
    private func fit(_ probe: XCUIElement, _ session: String) -> (t: Double, fit: Fit)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
              let t = (object["t"] as? NSNumber)?.doubleValue,
              let grids = object["grids"] as? [[String: Any]],
              let grid = grids.first(where: { $0["session"] as? String == session })
        else { return nil }
        let number = { (key: String) in (grid[key] as? NSNumber)?.intValue ?? -1 }
        return (t, Fit(cols: number("cols"), rows: number("rows"), resizes: number("resizes")))
    }

    /// The probe's numbers under `key` once `accept` takes them, or nil when it never does within ten
    /// seconds. Under "hover": screens captured since launch, and the picture's pixels while it shows.
    @MainActor
    private func measured(
        _ probe: XCUIElement, _ key: String, until accept: ([String: Int]) -> Bool = { _ in true }
    ) -> [String: Int]? {
        let deadline = Date.now.addingTimeInterval(10)
        repeat {
            if let object = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
               let numbers = object[key] as? [String: Any] {
                let numbers = numbers.compactMapValues { ($0 as? NSNumber)?.intValue }
                if accept(numbers) { return numbers }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date.now < deadline
        return nil
    }

    /// Photographs a scene in dark, then in light, as `<name>-dark.png` and `<name>-light.png`: `pose` sets
    /// the scene each time, and it holds still until tools/sidebar.sh has photographed it.
    @MainActor
    private func photograph(_ app: XCUIApplication, _ name: String, pose: () throws -> Void) throws {
        for (appearance, look) in [(XCUIDevice.Appearance.dark, "dark"), (.light, "light")] {
            XCUIDevice.shared.appearance = appearance
            try pose()
            // The keyboard and the look have finished changing.
            sleep(1)
            keep("\(name)-\(look)")
        }
        XCUIDevice.shared.appearance = .dark
    }

    /// Has tools/sidebar.sh photograph the screen as `name`.png, and holds still until it has: the test asks
    /// with an empty file, take-sidebar-<name>, in its runner's Documents, and the script answers with
    /// taken-sidebar-<name> (dest_photographer in tools/dest.zsh).
    @MainActor
    private func keep(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-sidebar-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-sidebar-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for the picture \(name)"
        )
        XCTAssertTrue(within(30) { FileManager.default.fileExists(atPath: taken) }, "tools/sidebar.sh never photographed \(name)")
    }

    /// Puts the on-screen keyboard down if it is up, or comes up within 3 seconds. Lhûn's key row has a Hide
    /// Keyboard button; without the key row, for the filter or beside a hardware keyboard as on a simulator,
    /// the keyboard's own key hides it.
    @MainActor
    private func keyboardDown(_ app: XCUIApplication) {
        let hide = app.buttons.matching(NSPredicate(format: "label ==[c] 'Hide keyboard'")).firstMatch
        let shows = { hide.exists && hide.isHittable }
        guard within(3, shows) else { return }
        hide.tap()
        XCTAssertTrue(within(10) { !shows() }, "the keyboard stayed up")
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

    /// The app keeps the layout: the run leaves the pills for whoever runs Lhûn on this iPad next.
    @MainActor
    private func leaveTabs(_ app: XCUIApplication, _ probe: XCUIElement) {
        if app.state != .runningForeground { app.launch() }
        let host = element(app, "host")
        if host.waitForExistence(timeout: 10) { return }
        try? palette(app, probe, "layout", run: "layout")
        XCTAssertTrue(host.waitForExistence(timeout: 10), "the sidebar layout stayed for the next run")
    }

    @MainActor
    private func holds(_ element: XCUIElement, _ format: String, _ arguments: CVarArg..., timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
