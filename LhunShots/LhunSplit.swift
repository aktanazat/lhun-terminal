import XCTest

final class LhunSplit: XCTestCase {
    @MainActor
    func testDroppedPillOpensBesideTheCard() throws {
        let (app, probe) = launch()
        let (a, b, c) = try fixtures()
        try open(app, a)

        drop(app, b, at: CGVector(dx: 0.75, dy: 0.55), shots: "drop-right")
        let split = settle(probe, "the session dropped on the right") { Set($0.map(\.session)) == [a, b] && focused($0) == b }
        assertFits(split, "two cards")
        assertLeftToRight(app, a, b)

        drop(app, c, at: CGVector(dx: 0.10, dy: 0.55), shots: "drop-left")
        let expanded = settle(probe, "the session dropped beside the left card") {
            Set($0.map(\.session)) == [a, b, c] && focused($0) == c
        }
        assertFits(expanded, "three cards")
        assertLeftToRight(app, c, a)
        assertLeftToRight(app, a, b)
        sleep(5)
        let start = try sample(probe)
        sleep(10)
        let end = try sample(probe)
        XCTAssertEqual(end["metal"], 3, "all cards should draw")
        XCTAssertEqual((end["frames"] ?? -1) - (start["frames"] ?? 0), 0, "three idle cards presented frames")
        let card = header(app, c).frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.midX, dy: card.maxY + 24)).tap()
        hideKeyboard(app)
        _ = settle(probe, "three cards with the keyboard down") { $0.count == 3 && focused($0) == nil }
        keep("split")

        app.typeKey("k", modifierFlags: .command)
        app.typeText("detach")
        app.descendants(matching: .any)["palette.detach"].firstMatch.tap()
        let remaining = settle(probe, "the dropped card detached") {
            Set($0.map(\.session)) == [a, b] && focused($0) == a
        }
        assertFits(remaining, "two cards remain")
        XCTAssertTrue(header(app, a).exists && header(app, b).exists)
        XCTAssertFalse(header(app, c).exists)
    }

    /// Split Right opens a new session, named after the focused one, in a card to its right. A card takes
    /// the focus by a tap, ⌘[ or ⌘]. A double tap on a card's header zooms it to the whole area and another
    /// brings both back; each way its terminal sends tmux exactly one size, not one per frame.
    @MainActor
    func testCardsTradeFocusAndZoom() throws {
        let (app, probe) = launch()
        let (a, _, _) = try fixtures()
        try open(app, a)
        app.typeKey("d", modifierFlags: .command)
        let twin = "\(a)-2"
        let split = settle(probe, "split right") { Set($0.map(\.session)) == [a, twin] && focused($0) == twin }
        assertFits(split, "split right")
        assertLeftToRight(app, a, twin)

        // The dimmed card takes the focus at a tap; the keys move it back and forth.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
        _ = settle(probe, "a tap on the left card") { focused($0) == a }
        app.typeKey("]", modifierFlags: .command)
        _ = settle(probe, "⌘]") { focused($0) == twin }
        app.typeKey("[", modifierFlags: .command)
        _ = settle(probe, "⌘[") { focused($0) == a }
        header(app, twin).staticTexts[twin].firstMatch.tap()
        _ = settle(probe, "a single tap on the right header") { $0.count == 2 && focused($0) == twin }
        header(app, a).staticTexts[a].firstMatch.tap()
        _ = settle(probe, "a single tap on the left header") { $0.count == 2 && focused($0) == a }

        let card = header(app, a).frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.midX, dy: card.maxY + 24)).tap()
        keyboardDown(app)
        XCTAssertTrue(OnScreenKeyboard(app).down(within: 5), "the keyboard stayed over the cards")
        let before = settle(probe, "two cards with the keyboard down") { $0.count == 2 }
        // On the card's name: on a narrow card the glyphs reach the middle of the header.
        let name = header(app, a).staticTexts[a].firstMatch
        name.doubleTap()
        let zoomed = settle(probe, "zoomed") { $0.map(\.session) == [a] }
        assertFits(zoomed, "zoomed")
        XCTAssertEqual(resizes(zoomed, a) - resizes(before, a), 1, "sizes the zoomed terminal sent tmux")
        keep("zoom")
        name.doubleTap()
        let restored = settle(probe, "restored") { Set($0.map(\.session)) == [a, twin] }
        assertFits(restored, "restored")
        XCTAssertEqual(resizes(restored, a) - resizes(zoomed, a), 1, "sizes the restored terminal sent tmux")

        let window = app.windows.firstMatch.frame
        let wasLandscape = window.width > window.height
        let original = XCUIDevice.shared.orientation
        let width = restored.first?.card.first
        XCUIDevice.shared.orientation = wasLandscape ? .portrait : .landscapeLeft
        let turned = settle(probe, "turned") { $0.count == 2 && $0.first?.card.first != width }
        assertFits(turned, "turned")
        keep(wasLandscape ? "portrait" : "landscape")
        XCUIDevice.shared.orientation = switch original {
        case .landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown: original
        default: wasLandscape ? .landscapeLeft : .portrait
        }
    }

    @MainActor
    func testNestedCardsFloatAndRestore() throws {
        let (app, probe) = launch()
        let (a, _, _) = try fixtures()
        try open(app, a)
        app.typeKey("d", modifierFlags: .command)
        let second = "\(a)-2"
        _ = settle(probe, "first split") { Set($0.map(\.session)) == [a, second] && focused($0) == second }
        app.typeKey("d", modifierFlags: [.command, .shift])
        let third = "\(second)-2"
        let nested = settle(probe, "nested split") {
            Set($0.map(\.session)) == [a, second, third] && focused($0) == third
        }
        assertFits(nested, "three cards")
        XCTAssertLessThan(header(app, a).frame.midX, header(app, second).frame.midX)
        XCTAssertLessThan(header(app, second).frame.midY, header(app, third).frame.midY)
        XCTAssertTrue(app.descendants(matching: .any)["gap.1"].firstMatch.exists)

        let float = header(app, third).descendants(matching: .any)["card.float"].firstMatch
        XCTAssertTrue(float.waitForExistence(timeout: 5))
        float.tap()
        let floating = settle(probe, "floating card") {
            Set($0.map(\.session)) == [a, second, third] && focused($0) == third
        }
        assertFits(floating, "floating card")
        let width = header(app, third).frame.width
        XCTAssertGreaterThan(width, header(app, second).frame.width)
        keep("three-cards-float")

        header(app, third).descendants(matching: .any)["card.float"].firstMatch.tap()
        let tiled = settle(probe, "card tiled again") { Set($0.map(\.session)) == [a, second, third] }
        assertFits(tiled, "three tiled cards")
        XCTAssertLessThan(header(app, third).frame.width, width)
        app.terminate()
        app.launchArguments = ["-keySeen", "YES", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let restored = settle(probe, "nested layout survives relaunch") {
            Set($0.map(\.session)) == [a, second, third]
        }
        assertFits(restored, "restored nested cards")
        XCTAssertLessThan(header(app, second).frame.midY, header(app, third).frame.midY)
    }

    @MainActor
    func testActivityHandsItsCardTheKeyboard() throws {
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer {
            if original == .landscapeLeft || original == .landscapeRight { XCUIDevice.shared.orientation = original }
        }
        let (app, probe) = launch()
        let (a, _, _) = try fixtures()
        try open(app, a)
        app.typeKey("d", modifierFlags: .command)
        let twin = "\(a)-2"
        _ = settle(probe, "split right") { Set($0.map(\.session)) == [a, twin] && focused($0) == twin }
        let before = settle(probe, "the pair before activity opens") { $0.count == 2 && focused($0) == twin }
        activity(app, in: a, member: a).tap()
        let first = settle(probe, "the first terminal chosen from activity") { Set($0.map(\.session)) == [a, twin] && focused($0) == a }
        for session in [a, twin] {
            XCTAssertEqual(resizes(first, session), resizes(before, session), "activity resized \(session)")
        }
        activity(app, in: a, member: twin).tap()
        _ = settle(probe, "the second terminal chosen from activity") { Set($0.map(\.session)) == [a, twin] && focused($0) == twin }
        onStrip(app, a).tap()
        _ = settle(probe, "the tab restores its focused terminal") { Set($0.map(\.session)) == [a, twin] && focused($0) == twin }
    }

    @MainActor
    func testTabsKeepIndependentTerminalGroups() throws {
        let (app, probe) = launch()
        let (a, b, _) = try fixtures()
        try open(app, a)
        app.typeKey("d", modifierFlags: .command)
        let aTwin = "\(a)-2"
        _ = settle(probe, "the first tab's split") { Set($0.map(\.session)) == [a, aTwin] && focused($0) == aTwin }
        try open(app, b)
        _ = settle(probe, "the unrelated tab opens alone") { $0.map(\.session) == [b] && focused($0) == b }
        app.typeKey("d", modifierFlags: [.command, .shift])
        let bTwin = "\(b)-2"
        _ = settle(probe, "the second tab's split") { Set($0.map(\.session)) == [b, bTwin] && focused($0) == bTwin }
        assertTopToBottom(app, b, bTwin)
        onStrip(app, a).tap()
        _ = settle(probe, "the first pair returns") { Set($0.map(\.session)) == [a, aTwin] && focused($0) == aTwin }
        assertLeftToRight(app, a, aTwin)
        onStrip(app, b).tap()
        _ = settle(probe, "the second pair returns") { Set($0.map(\.session)) == [b, bTwin] && focused($0) == bTwin }
        assertTopToBottom(app, b, bTwin)
        keep("rex-two-workspaces-tabs")
        app.terminate()
        app.launchArguments = ["-keySeen", "YES", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        _ = settle(probe, "the second workspace survives relaunch") { Set($0.map(\.session)) == [b, bTwin] }
        onStrip(app, a).tap()
        _ = settle(probe, "the inactive workspace survives relaunch") { Set($0.map(\.session)) == [a, aTwin] }
        assertLeftToRight(app, a, aTwin)
    }

    /// Split Down opens a new session, named after the focused one and in its folder, in a card below it,
    /// with the focus. A tap, ⌘[ and ⌘] move the focus in reading order, the top card first. Only the
    /// focused card's glyphs act: where the other card's zoom would be, a tap only gives that card the
    /// focus. Each glyph's target is 44 points square, the header's height. The zoom glyph zooms the
    /// card and brings both back, each way sending tmux exactly one size, and the close glyph takes the card
    /// away, leaving the other alone.
    @MainActor
    func testCardsStack() throws {
        let (app, probe) = launch()
        let (a, _, _) = try fixtures()
        try open(app, a)
        app.typeKey("d", modifierFlags: [.command, .shift])
        let twin = "\(a)-2"
        let stacked = settle(probe, "split down") { Set($0.map(\.session)) == [a, twin] && focused($0) == twin }
        assertFits(stacked, "split down")
        assertTopToBottom(app, a, twin)
        // Both headers name the same program and folder: the new session started where the first one is.
        XCTAssertFalse(detail(app, a).isEmpty, "\(a)'s header shows no folder")
        XCTAssertEqual(detail(app, twin), detail(app, a), "the new session started somewhere else")

        // The dimmed top card takes the focus at a tap; the keys move it down and back up.
        let top = header(app, a).frame
        // Just under the header: with the keyboard up, the gap's grip reaches into the card's last points.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: top.midX, dy: top.maxY + 24)).tap()
        _ = settle(probe, "a tap on the top card") { focused($0) == a }
        app.typeKey("]", modifierFlags: .command)
        _ = settle(probe, "⌘]") { focused($0) == twin }
        app.typeKey("[", modifierFlags: .command)
        _ = settle(probe, "⌘[") { focused($0) == a }

        // The focused header's glyphs are 44 points wide. The other header's take no taps: where its zoom
        // would be, a tap only moves the focus there.
        for id in ["splitRight", "splitDown", "zoom", "close"] {
            XCTAssertEqual(header(app, a).descendants(matching: .any)["card.\(id)"].firstMatch.frame.width, 44, "\(id)'s width")
        }
        let zoomX = header(app, a).descendants(matching: .any)["card.zoom"].firstMatch.frame.midX
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: zoomX, dy: header(app, twin).frame.midY)).tap()
        _ = settle(probe, "a tap on the lower header") { focused($0) == twin }
        // A zoom would take the other card away within its 0.3 s move.
        sleep(2)
        XCTAssertEqual(Set(grids(probe)?.grids.map(\.session) ?? []), [a, twin], "a tap on the unfocused header's glyphs zoomed it")
        app.typeKey("[", modifierFlags: .command)
        _ = settle(probe, "⌘[ back to the top card") { focused($0) == a }
        // The keyboard goes down with the picture, so the only change in size is the zoom's.
        shoot(app, "stacked", typedInto: a)
        let before = settle(probe, "stacked with the keyboard down") { $0.count == 2 }
        assertFits(before, "stacked with the keyboard down")
        let zoom = header(app, a).descendants(matching: .any)["card.zoom"].firstMatch
        zoom.tap()
        let zoomed = settle(probe, "zoomed") { $0.map(\.session) == [a] }
        assertFits(zoomed, "zoomed")
        XCTAssertEqual(resizes(zoomed, a) - resizes(before, a), 1, "sizes the zoomed terminal sent tmux")
        // Near the bottom of the glyph's 44 points, well below the glyph itself, the tap still restores.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: zoom.frame.midX, dy: header(app, a).frame.minY + 40)).tap()
        let restored = settle(probe, "restored") { Set($0.map(\.session)) == [a, twin] }
        assertFits(restored, "restored")
        XCTAssertEqual(resizes(restored, a) - resizes(zoomed, a), 1, "sizes the restored terminal sent tmux")
        assertTopToBottom(app, a, twin)

        header(app, a).descendants(matching: .any)["card.close"].firstMatch.tap()
        let single = settle(probe, "the top card closed") { $0.map(\.session) == [twin] }
        assertFits(single, "one card again")
        XCTAssertFalse(header(app, a).exists, "the closed card stayed")
    }

    @MainActor
    func testGapResizes() throws {
        let (app, probe) = launch()
        let (a, b, c) = try fixtures()
        try open(app, a)

        drop(app, b, at: CGVector(dx: 0.5, dy: 0.92), shots: "drop-bottom")
        let stacked = settle(probe, "the session dropped on the bottom") { Set($0.map(\.session)) == [a, b] && focused($0) == b }
        assertFits(stacked, "dropped below")
        assertTopToBottom(app, a, b)
        dragGap(app, probe, to: 0.65, stacked: true, first: a, second: b)
        let gap = app.descendants(matching: .any)["gap"].firstMatch
        let lower = percent(gap)

        // The bottom card, dropped on the right half, moves beside the top one, and the pair keeps its share.
        drop(app, b, at: CGVector(dx: 0.85, dy: 0.25), fromTab: a)
        _ = settle(probe, "the bottom card moved right") { grids in
            Set(grids.map(\.session)) == [a, b] && grids.allSatisfy { $0.card.first != card(stacked, $0.session).first }
        }
        assertLeftToRight(app, a, b)
        XCTAssertEqual(percent(gap), lower, "the pair's share once side by side")
        let narrow = dragGap(app, probe, to: 0.30, stacked: false, first: a, second: b)
        shoot(app, "resize-30-70", typedInto: b)

        // A third card divides the right card, leaving the resized root split alone.
        drop(app, c, at: CGVector(dx: 0.90, dy: 0.55))
        let expanded = settle(probe, "a third card") { Set($0.map(\.session)) == [a, b, c] && focused($0) == c }
        assertFits(expanded, "nested split")
        XCTAssertEqual(percent(gap), 30, "the outer split keeps its share")
        let inner = app.descendants(matching: .any)["gap.1"].firstMatch
        XCTAssertTrue(inner.waitForExistence(timeout: 5))
        XCTAssertEqual(percent(inner), 50, "the new split starts even")
        let middle = CGPoint(x: inner.frame.midX, y: inner.frame.midY)
        let room = header(app, c).frame.maxX - header(app, b).frame.minX - 8
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: middle.x, dy: middle.y))
        from.press(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: room * 0.1, dy: 0)),
                   withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.5)
        let resized = settle(probe, "nested gap resized") {
            Set($0.map(\.session)) == [a, b, c] && $0.allSatisfy { $0.fit == "ok" }
        }
        XCTAssertEqual(percent(inner), 60)
        XCTAssertEqual(card(resized, a), card(expanded, a), "the outer card did not change size")
        for session in [b, c] {
            XCTAssertEqual(resizes(resized, session) - resizes(expanded, session), 1, "\(session) resized once")
        }
        shoot(app, "header-buttons", typedInto: c)
        app.typeKey("k", modifierFlags: .command)
        app.typeText("detach")
        app.descendants(matching: .any)["palette.detach"].firstMatch.tap()
        keyboardDown(app)
        let back = settle(probe, "the first pair again") { Set($0.map(\.session)) == [a, b] }
        assertFits(back, "the first pair again")
        XCTAssertEqual(percent(gap), 30, "the first pair's share")
        for session in [a, b] {
            XCTAssertEqual(card(back, session), card(narrow, session), "\(session)'s card at the pair's share")
        }

        sleep(5)
        let start = try sample(probe)
        sleep(10)
        let end = try sample(probe)
        XCTAssertEqual(end["metal"], 2, "both cards should draw")
        XCTAssertEqual((end["frames"] ?? -1) - (start["frames"] ?? 0), 0, "two idle cards presented frames")
    }

    @MainActor
    private func launch() -> (app: XCUIApplication, probe: XCUIElement) {
        let app = XCUIApplication()
        // Every pair of sessions starts even, whatever an earlier run left.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-shares", "{}", "-layout", "tabs"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        return (app, probe)
    }

    /// Opens the session with its pill and waits for it to attach, then presses one key that types
    /// nothing: XCUITest's first key after a launch can go astray.
    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        onStrip(app, name).tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        terminal.tap()
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sleep(2)
    }

    @MainActor
    private func hideKeyboard(_ app: XCUIApplication) {
        XCTAssertTrue(OnScreenKeyboard(app).putDown(ifUpWithin: 10), "the keyboard never came up")
    }

    /// Puts the on-screen keyboard down if it is up, or comes up within 3 seconds.
    @MainActor
    private func keyboardDown(_ app: XCUIApplication) {
        OnScreenKeyboard(app).putDown(ifUpWithin: 3)
    }

    /// Schedules a device picture through `shoot` in a tools/split.sh session after typing into that session.
    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String, typedInto session: String) {
        let card = header(app, session).frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.midX, dy: card.maxY + 24)).tap()
        app.typeText("shoot \(name) 3\n")
        keyboardDown(app)
        XCTAssertTrue(OnScreenKeyboard(app).down(within: 5), "the keyboard stayed over the card")
        sleep(5)
    }

    /// Drags `name`'s pill from the strip onto the cards at `point`, a share of the screen's width and
    /// height, and lets go. A drag begins only after a press of half a second; a longer one opens the pill's
    /// menu, and a slow drag scrubs through it. With `shots`, it holds the pill there for 8 seconds while
    /// the Mac photographs the screen every two, `<shots>-<n>.png`; tools/split.sh keeps the last before the
    /// drop.
    @MainActor
    private func drop(_ app: XCUIApplication, _ name: String, at point: CGVector, shots: String? = nil, fromTab: String? = nil) {
        if let shots {
            let times = (1...5).map { "\(shots)-\($0) \(4 + 2 * $0)" }.joined(separator: " ")
            app.typeText("shoot \(times)\n")
        }
        // The keyboard goes down, so the cards show whole while the pill hangs over them.
        keyboardDown(app)
        let pill = fromTab.map { activity(app, in: $0, member: name) } ?? onStrip(app, name)
        let target = app.windows.firstMatch.coordinate(withNormalizedOffset: point)
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: target, withVelocity: .default, thenHoldForDuration: shots == nil ? 1 : 8)
    }

    @MainActor
    private func activity(_ app: XCUIApplication, in root: String, member: String) -> XCUIElement {
        _ = onStrip(app, root)
        let opener = app.buttons["session.more.mac.\(root)"].firstMatch
        XCTAssertTrue(opener.waitForExistence(timeout: 5), "the tab has no activity control")
        opener.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.row.mac\t\(member)\t")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the terminal has no activity row")
        return row
    }

    /// With the keyboard down, drags the gap between the cards so the first takes `share` of the room the
    /// gap leaves, and lets go. Each terminal must send tmux exactly one size for the whole drag and then fit
    /// its card. Afterwards it waits 3 seconds, so tools/split.sh finds nothing else near the moment the gap
    /// let go when it counts the sizes tmux took.
    @MainActor
    @discardableResult
    private func dragGap(
        _ app: XCUIApplication, _ probe: XCUIElement, to share: CGFloat, stacked: Bool, first: String, second: String
    ) -> [Grid] {
        keyboardDown(app)
        let before = settle(probe, "two cards at rest before the drag") { $0.count == 2 && focused($0) == nil }
        let gap = app.descendants(matching: .any)["gap"].firstMatch
        XCTAssertTrue(gap.waitForExistence(timeout: 5), "no gap between the cards")
        // The gap is 8 points, and the first card starts where its header does.
        let start = header(app, first).frame
        let middle: CGPoint
        let now: CGFloat
        let room: CGFloat
        if stacked {
            middle = CGPoint(x: gap.frame.midX, y: gap.frame.maxY - 4)
            now = CGFloat(percent(gap)) / 100
            room = (middle.y - 4 - start.minY) / now
        } else {
            middle = CGPoint(x: gap.frame.midX, y: gap.frame.midY)
            room = header(app, second).frame.maxX - start.minX - 8
            now = (middle.x - 4 - start.minX) / room
        }
        let distance = (share - now) * room
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: middle.x, dy: middle.y))
        let to = from.withOffset(stacked ? CGVector(dx: 0, dy: distance) : CGVector(dx: distance, dy: 0))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.5)
        let after = settle(probe, "the gap let go at \(share)") { grids in
            grids.count == 2 && focused(grids) == nil && grids.allSatisfy { grid in card(before, grid.session) != grid.card }
        }
        assertFits(after, "the gap let go at \(share)")
        for session in [first, second] {
            XCTAssertEqual(resizes(after, session) - resizes(before, session), 1, "sizes \(session) sent tmux for one drag")
        }
        XCTAssertEqual(percent(gap), Int((share * 100).rounded()), "the gap's share")
        sleep(3)
        return after
    }

    /// The sessions tools/split.sh made for this run: <SPLIT_PREFIX>-a, -b and -c.
    private func fixtures() throws -> (String, String, String) {
        let prefix = try XCTUnwrap(ProcessInfo.processInfo.environment["SPLIT_PREFIX"], "run this test through tools/split.sh")
        return ("\(prefix)-a", "\(prefix)-b", "\(prefix)-c")
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["card.mac.\(name)"].firstMatch
    }

    /// What a card's header says besides the session's name: the program it runs and its folder.
    @MainActor
    private func detail(_ app: XCUIApplication, _ name: String) -> [String] {
        header(app, name).staticTexts.allElementsBoundByIndex.map(\.label).filter { $0 != name }
    }

    /// The first card's share of the room, in whole percent, as the gap between the cards reports it.
    @MainActor
    private func percent(_ gap: XCUIElement) -> Int {
        Int((gap.value as? String ?? "").dropLast()) ?? -1
    }

    /// The cards' headers sit in this order from the left.
    @MainActor
    private func assertLeftToRight(_ app: XCUIApplication, _ left: String, _ right: String) {
        XCTAssertTrue(header(app, left).exists && header(app, right).exists, "two cards should carry headers")
        XCTAssertLessThan(header(app, left).frame.midX, header(app, right).frame.midX, "\(left) should be left of \(right)")
    }

    /// The cards' headers sit in this order from the top, one card above the other.
    @MainActor
    private func assertTopToBottom(_ app: XCUIApplication, _ upper: String, _ lower: String) {
        XCTAssertTrue(header(app, upper).exists && header(app, lower).exists, "two cards should carry headers")
        XCTAssertLessThan(header(app, upper).frame.maxY, header(app, lower).frame.minY, "\(upper) should be above \(lower)")
        XCTAssertEqual(header(app, upper).frame.minX, header(app, lower).frame.minX, "the stacked cards' left edges")
    }

    /// The whole screen: an app's own screenshot is cut to its frame when the iPad is held sideways.
    /// tools/split.sh turns these the way the iPad is held.
    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// One terminal on screen as the probe reports it. The probe lists them in no particular order.
    private struct Grid: Equatable, CustomStringConvertible {
        let session: String
        let cols: Int
        let rows: Int
        let fit: String
        let card: [Double]
        let focused: Bool
        let resizes: Int

        var description: String {
            "\(session) \(cols)x\(rows) card \(card) focused \(focused) resizes \(resizes): \(fit)"
        }
    }

    /// The session whose terminal takes typing, if one does.
    private func focused(_ grids: [Grid]) -> String? {
        grids.first(where: \.focused)?.session
    }

    private func resizes(_ grids: [Grid], _ session: String) -> Int {
        grids.first { $0.session == session }?.resizes ?? -1
    }

    /// The size of the session's terminal host on its card, as the probe reports it.
    private func card(_ grids: [Grid], _ session: String) -> [Double] {
        grids.first { $0.session == session }?.card ?? []
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
