import XCTest

/// Session marks after he leaves a session, on the iPad or a simulator, against three quiet zsh sessions
/// on this Mac that tools/remark.sh makes: lhun-test-remark-a, -b and -c.
final class LhunRemark: XCTestCase {
    private static let prefix = "lhun-test-remark"
    /// Lhûn plays no chime within 10 seconds of the last one (`Chime.spacing`).
    private static let chimeSpacing: TimeInterval = 10

    /// Six times over, a job finishes in front of him and he moves on to the next session at once, before
    /// tmux's next report, which comes up to a second late. The session he left gets no mark and no
    /// chime: everything in it, he saw.
    @MainActor
    func testLeavingASessionHeSawIsNotNews() throws {
        let (app, probe) = launch()
        let order = ["a", "b", "c", "a", "b", "c", "a"]
        try open(app, order[0])
        for (left, next) in zip(order, order.dropFirst()) {
            // A job tmux reports as working, until a Return finishes it in front of him.
            app.typeText("head -1 >/dev/null\r")
            Thread.sleep(forTimeInterval: 1.5)
            app.typeText("\r")
            // He leaves at once, with one tap on the next session's pill and no wait for it to appear, so he
            // is gone before tmux's report of the finish. A slow leave lets that report arrive while he is
            // still there, which misses what this checks. The tap is the element's own, which scrolls the
            // strip until the pill shows: a pill can sit half past the strip's end.
            pill(app, next).tap()
            try attached(app, next)
            stayUnmarked(app, left, seconds: 4)
            XCTAssertFalse(chimes(probe).contains(name(left)), "a chime played for \(left) after he left it")
        }
    }

    /// What happens after he leaves is news, with a chime: a job that finishes gets the finished mark, one
    /// that rings the stronger one, and so does a program that finishes by changing only its title,
    /// printing nothing.
    @MainActor
    func testWhatHappensAfterHeLeavesIsNews() throws {
        let (app, probe) = launch()
        try open(app, "a")
        app.typeText("sleep 4\r")
        try open(app, "b")
        try waitFor(pill(app, "a"), "finished", timeout: 20)
        try waitUntil(5, "no chime played for a") { chimes(probe).contains(name("a")) }
        Thread.sleep(forTimeInterval: Self.chimeSpacing)

        try open(app, "c")
        app.typeText("sleep 4; printf '\\a'\r")
        try open(app, "b")
        try waitFor(pill(app, "c"), "needs you", timeout: 20)
        try waitUntil(5, "no chime played for c") { chimes(probe).contains(name("c")) }
        Thread.sleep(forTimeInterval: Self.chimeSpacing)

        // omp's titles, typed as octal escapes: "π ⠋" while it works, then "π >" at its prompt.
        try open(app, "a")
        app.typeText("printf '\\033]2;\\317\\200 \\342\\240\\213 working\\033\\\\'; read -t 3; ")
        app.typeText("printf '\\033]2;\\317\\200 > ready\\033\\\\'; read\r")
        try open(app, "b")
        try waitFor(pill(app, "a"), "finished", timeout: 20)
        try waitUntil(5, "no chime played for a's second finish") { chimes(probe).filter { $0 == name("a") }.count == 2 }
    }

    // MARK: Steps

    @MainActor
    private func launch() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-sounds", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        return (app, probe)
    }

    private func name(_ session: String) -> String {
        "\(Self.prefix)-\(session)"
    }

    @MainActor
    private func pill(_ app: XCUIApplication, _ session: String) -> XCUIElement {
        app.descendants(matching: .any)["session.mac.\(name(session))"].firstMatch
    }

    /// The sessions the chimes so far played for, oldest first, from the probe's latest line.
    @MainActor
    private func chimes(_ probe: XCUIElement) -> [String] {
        let sample = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        return (sample?["chimes"] as? [[String: String]] ?? []).compactMap { $0["name"] }
    }

    /// Opens the session from its pill, waits until it attaches, and gives its terminal the keyboard.
    @MainActor
    private func open(_ app: XCUIApplication, _ session: String) throws {
        let pill = pill(app, session)
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(session) never appeared")
        pill.tap()
        try attached(app, session)
    }

    /// Waits until the session just tapped attaches and shows as open, and gives its terminal the keyboard.
    @MainActor
    private func attached(_ app: XCUIApplication, _ session: String) throws {
        let pill = pill(app, session)
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened for \(session)")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(session) never attached")
        try waitUntil(10, "\(session) never showed as open") { pill.isSelected }
        terminal.tap()
    }

    /// Watches the session's pill for `seconds`, failing on the first mark it shows.
    @MainActor
    private func stayUnmarked(_ app: XCUIApplication, _ session: String, seconds: TimeInterval) {
        let pill = pill(app, session)
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            let mark = pill.value as? String ?? ""
            if !mark.isEmpty {
                XCTFail("\(session) showed \"\(mark)\" after he left it")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    @MainActor
    private func waitFor(_ pill: XCUIElement, _ mark: String, timeout: TimeInterval) throws {
        try waitUntil(timeout, "\(pill.identifier)'s mark never became \"\(mark)\"; it is \"\(pill.value as? String ?? "")\"") {
            (pill.value as? String ?? "") == mark
        }
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
}
