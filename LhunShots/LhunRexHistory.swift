import XCTest

final class LhunRexHistory: XCTestCase {
    @MainActor
    func testFindSearchesOlderRetainedRows() throws {
        let (app, probe) = openFixture()
        try typeCommand("f", .command, in: app, probe: probe)
        let history = app.textViews["history"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "find did not finish loading history")
        XCTAssertGreaterThan(measure(probe, "rows"), 500, "older rows were not loaded")
        field.typeText("LHUN_OLDER_MATCH")
        let next = app.buttons.matching(NSPredicate(format: "label == %@", "Next Result")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(waitFor(probe, "back", atLeast: 500, within: 10), "find did not jump to the older match")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "full-history-find"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPreviousPromptJumpsAcrossRetainedHistory() {
        let (app, probe) = openFixture()
        previousPrompt(app)
        let history = app.textViews["history"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 30))
        XCTAssertTrue(waitFor(probe, "promptRows", atLeast: 2, within: 30), "tmux prompt marks did not load")
        let recent = measure(probe, "back")
        previousPrompt(app)
        XCTAssertTrue(waitFor(probe, "back", atLeast: recent + 500, within: 20), "the older prompt did not scroll into view")
    }

    @MainActor
    func testSavedShortcutOpensAllSessionsAfterRelaunch() throws {
        let (app, probe) = openFixture(resetBindings: true)
        bindingEditor(app)
        let record = app.buttons["bindings.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        app.typeKey("u", modifierFlags: [.command, .alternate])
        let save = app.buttons["bindings.save"].firstMatch
        XCTAssertTrue(save.isEnabled, "the recorded shortcut was rejected")
        save.tap()
        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(app.textFields["bindings.query"].waitForNonExistence(timeout: 10))
        app.textViews["terminal"].firstMatch.tap()
        app.typeKey("u", modifierFlags: [.command, .alternate])
        let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the saved shortcut did not open sessions")

        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        openSession(app)
        app.typeKey("u", modifierFlags: [.command, .alternate])
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the shortcut did not survive relaunch")

        app.terminate()
        app.launch()
        openSession(app)
        bindingEditor(app)
        let remove = app.buttons["Remove Binding"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
    }

    @MainActor
    func testTwoKeyShortcutWaitsForSecondKey() throws {
        let (app, probe) = openFixture(resetBindings: true)
        bindingEditor(app)
        let twoKeys = app.segmentedControls.buttons["Two Keys"].firstMatch
        XCTAssertTrue(twoKeys.waitForExistence(timeout: 10))
        twoKeys.tap()
        app.buttons["bindings.record"].firstMatch.tap()
        app.typeKey("u", modifierFlags: [.command, .alternate])
        app.typeKey("z", modifierFlags: [])
        let save = app.buttons["bindings.save"].firstMatch
        XCTAssertTrue(save.isEnabled, "the two-key shortcut was rejected")
        save.tap()
        try typeCommand("k", .command, in: app, probe: probe)
        XCTAssertTrue(app.textFields["bindings.query"].waitForNonExistence(timeout: 10))
        app.textViews["terminal"].firstMatch.tap()
        app.typeKey("u", modifierFlags: [.command, .alternate])
        let pending = app.descendants(matching: .any)["bindings.pending"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "the first key did not wait")
        let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
        XCTAssertFalse(grid.exists, "the first key ran the action too early")
        app.typeKey("z", modifierFlags: [])
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the second key did not run the action")
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10))

        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        openSession(app)
        bindingEditor(app)
        app.buttons["Remove Binding"].firstMatch.tap()
    }

    @MainActor
    func testOneShotRunsOnePlainKey() {
        let (app, _) = openFixture(resetBindings: true)
        bindingEditor(app)
        let oneShot = app.segmentedControls.buttons["One-Shot"].firstMatch
        XCTAssertTrue(oneShot.waitForExistence(timeout: 10))
        oneShot.tap()
        app.buttons["bindings.record"].firstMatch.tap()
        app.typeKey("q", modifierFlags: [])
        let save = app.buttons["bindings.save"].firstMatch
        XCTAssertTrue(save.isEnabled, "the plain one-shot key was rejected")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        let bindingQuery = app.textFields["bindings.query"].firstMatch
        XCTAssertTrue(bindingQuery.waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(bindingQuery.waitForNonExistence(timeout: 10))
        app.buttons["palette"].firstMatch.tap()
        let query = app.textFields["palette.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.typeText("One-Shot Keys")
        let start = app.descendants(matching: .any)["palette.one-shot-keys"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let pending = app.descendants(matching: .any)["bindings.pending"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "one-shot mode did not start")
        app.textViews["terminal"].firstMatch.tap()
        app.typeKey("q", modifierFlags: [])
        let grid = app.descendants(matching: .any)["peek.grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the plain key did not run its one-shot action")
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10), "one-shot mode did not end")

        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        openSession(app)
        bindingEditor(app)
        let oneShotAgain = app.segmentedControls.buttons["One-Shot"].firstMatch
        XCTAssertTrue(oneShotAgain.waitForExistence(timeout: 10))
        oneShotAgain.tap()
        XCTAssertTrue(oneShotAgain.isSelected)
        let remove = app.buttons["Remove Binding"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
    }

    @MainActor
    func testSavedWindowShortcutWorksAfterWindowListChanges() {
        let (app, _) = openFixture(resetBindings: true)
        let pill = app.buttons["session.mac.lhun-rex-history"].firstMatch
        app.typeText("tmux new-window -n shortcut-check\n")
        XCTAssertTrue(pillShows(pill, window: 1))

        app.typeKey("k", modifierFlags: .command)
        app.typeText("Keyboard Bindings")
        let manager = app.descendants(matching: .any)["palette.bindings"].firstMatch
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        manager.tap()
        let query = app.textFields["bindings.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.typeText("window")
        let row = app.descendants(matching: .any)["bindings.window.0"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let record = app.buttons["bindings.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        app.typeKey("u", modifierFlags: [.command, .alternate])
        let save = app.buttons["bindings.save"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForNonExistence(timeout: 10))
        app.textViews["terminal"].firstMatch.tap()

        app.typeKey("u", modifierFlags: [.command, .alternate])
        XCTAssertTrue(pillShows(pill, window: 0), "the first shortcut did not select the saved window")
        app.typeText("tmux select-window -t 1\n")
        XCTAssertTrue(pillShows(pill, window: 1))
        app.typeKey("u", modifierFlags: [.command, .alternate])
        XCTAssertTrue(pillShows(pill, window: 0), "the shortcut stopped working after the window list cleared")
        app.typeText("tmux kill-window -t 1\n")

        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        openSession(app)
        app.typeKey("k", modifierFlags: .command)
        app.typeText("Keyboard Bindings")
        let bindings = app.descendants(matching: .any)["palette.bindings"].firstMatch
        XCTAssertTrue(bindings.waitForExistence(timeout: 10))
        bindings.tap()
        let search = app.textFields["bindings.query"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("window")
        let saved = app.descendants(matching: .any)["bindings.window.0"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        let remove = app.buttons["Remove Binding"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
    }

    @MainActor
    func testActivityKeepsPaneTitleWithoutProtocolTitle() {
        let (app, _) = openFixture()
        let folder = "/private/var/tmp/lhun-rex-title-\(UUID().uuidString)"
        app.typeText("mkdir -p \(folder); printf '#include <unistd.h>\\nint main(void) { sleep(120); return 0; }\\n' > \(folder)/claude.c; /usr/bin/clang -o \(folder)/claude \(folder)/claude.c; tmux select-pane -T '✳ fix login redirect'; printf '\\033]7501;id=planner:state=clear\\033\\\\'; printf '\\033]7501;state=working:app=claude-code\\033\\\\'; \(folder)/claude\n")
        let activity = app.buttons["session.more.mac.lhun-rex-history"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        let panel = app.descendants(matching: .any)["tab.activity"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let record = panel.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        let title = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "fix login redirect"), object: record
        )
        XCTAssertEqual(XCTWaiter().wait(for: [title], timeout: 20), .completed, "the pane title was missing: \(record.label)")
        app.buttons["tab.activity.close"].firstMatch.tap()
        app.textViews["terminal"].firstMatch.tap()
        app.typeKey("c", modifierFlags: .control)
        app.typeText("tmux select-pane -T zsh; printf '\\033]7501;state=clear\\033\\\\'; rm -f \(folder)/claude \(folder)/claude.c; rmdir \(folder)\n")
    }

    @MainActor
    private func bindingEditor(_ app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        app.typeText("Keyboard Bindings")
        let manager = app.descendants(matching: .any)["palette.bindings"].firstMatch
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        manager.tap()
        let query = app.textFields["bindings.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.typeText("Show All Sessions")
        let row = app.descendants(matching: .any)["bindings.peek"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["bindings.record"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func openSession(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["session.mac.lhun-rex-history"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30))
        terminal.tap()
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
    }

    @MainActor
    private func openFixture(resetBindings: Bool = false) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"]
        if resetBindings { app.launchArguments += ["-actionBindings", ""] }
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        openSession(app)
        return (app, probe)
    }

    @MainActor
    private func previousPrompt(_ app: XCUIApplication) {
        app.typeKey("k", modifierFlags: .command)
        app.typeText("previous prompt")
        let action = app.descendants(matching: .any)["palette.history.prompt.previous"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
    }

    @MainActor
    private func pillShows(_ pill: XCUIElement, window: Int) -> Bool {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ":\(window)"), object: pill
        )
        return XCTWaiter().wait(for: [expected], timeout: 15) == .completed
    }

    @MainActor
    private func measure(_ probe: XCUIElement, _ key: String) -> Int {
        guard let data = probe.label.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = root["history"] as? [String: Any] else { return 0 }
        return (history[key] as? NSNumber)?.intValue ?? 0
    }

    @MainActor
    private func waitFor(_ probe: XCUIElement, _ key: String, atLeast minimum: Int, within seconds: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if measure(probe, key) >= minimum { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}
