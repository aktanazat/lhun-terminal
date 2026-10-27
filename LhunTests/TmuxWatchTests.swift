import Testing
@testable import LhunKit

// MARK: Reading the watcher's output

/// A line in the shape tmux 3.7c sent a watcher attached through a pseudo-terminal: two sessions, the
/// first with a bell waiting, an agent title at its prompt and omp's model on its pane, the second with a
/// window in the background at index 1, whose pane has a model too that only a shown pane would report,
/// and where a program reports that it waits on a question (`@lhun-status`, which lhun-tap sets).
private let capturedLine = "%subscription-changed lhun $1348 - - - : "
    + "lhun-test-clawd-w2\u{1F}@1393\u{1F}0\u{1F}1\u{1F}1\u{1F}sleep\u{1F}/private/var/tmp/lhun-clawd\u{1F}0\u{1F}hidden\u{1F}π > \u{1F}anthropic/claude-opus-5-5\u{1F}\u{1F}\u{1F}%1393\u{1E}"
    + "lhun-test-clawd-w3\u{1F}@1394\u{1F}0\u{1F}0\u{1F}1\u{1F}zsh\u{1F}/private/var/tmp/lhun-clawd\u{1F}0\u{1F}hidden\u{1F}/pri\u{1F}\u{1F}\u{1F}\u{1F}%1394\u{1E}"
    + "lhun-test-clawd-w3\u{1F}@1395\u{1F}1\u{1F}0\u{1F}0\u{1F}zsh\u{1F}\u{1F}0\u{1F}hidden\u{1F}/pri\u{1F}\u{1F}"
    + "state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1\u{1F}\u{1F}%1395\u{1E}\r\n"

private let capturedPanes = [
    PaneReport(
        session: "lhun-test-clawd-w2", window: "@1393", windowIndex: 0, windowBell: true, isShown: true, command: "sleep",
        path: "/private/var/tmp/lhun-clawd", alternateScreen: false, progress: .none, title: "π > ",
        model: "anthropic/claude-opus-5-5", pane: "%1393"
    ),
    PaneReport(
        session: "lhun-test-clawd-w3", window: "@1394", windowIndex: 0, windowBell: false, isShown: true, command: "zsh",
        path: "/private/var/tmp/lhun-clawd", alternateScreen: false, progress: .none, title: "/pri", model: "", pane: "%1394"
    ),
    PaneReport(
        session: "lhun-test-clawd-w3", window: "@1395", windowIndex: 1, windowBell: false, isShown: false, command: "zsh",
        path: "", alternateScreen: false, progress: .none, title: "/pri", model: "",
        status: ProgramStatus(summary: "state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1"), pane: "%1395"
    ),
]

@Test func capturedSubscriptionLineReadsAsPanes() {
    var stream = TmuxWatch.Stream()
    let events = stream.feed(Array(capturedLine.utf8))
    #expect(events == [.panes(capturedPanes, seen: [])])
}

/// A tmux 3.4 capture with octal-escaped separators, expanded with the watcher's newer fields.
private let linuxReport = "%subscription-changed lhun $0 - - - : "
    + "lhun-test-remark-look\u{1F}@0\u{1F}0\u{1F}0\u{1F}1\u{1F}sh\u{1F}/root\u{1F}0\u{1F}\u{1F}π ⠿ \u{1F}\u{1F}\u{1F}\u{1F}%0\u{1E}\r\n"
private let linuxAnswer = "%begin 1791510839 280 1\r\n"
    + #"lhun-test-remark-look\037@0\0370\0370\0371\037sh\037/root\0370\037\037π ⠿ \037\037\037\037%0\036"# + "\r\n"
    + "%end 1791510839 280 1\r\n"
private let linuxPanes = [pane("lhun-test-remark-look", window: "@0", command: "sh", path: "/root", title: "π ⠿ ")]

@Test func outputSplitAnywhereReadsTheSame() {
    let bytes = Array(("home /Users/me\r\n" + capturedLine + linuxAnswer + "%sessions-changed\r\n").utf8)
    let left: Set = ["lhun-test-remark-look"]
    let expected: [TmuxWatch.Event] = [
        .home("/Users/me"), .panes(capturedPanes, seen: left), .panes(linuxPanes, seen: left), .sessionsChanged,
    ]
    // Every cut, including the ones inside "π", inside an escape and inside a line ending.
    for cut in 0...bytes.count {
        var stream = TmuxWatch.Stream()
        _ = stream.look(leaving: "lhun-test-remark-look")
        let events = stream.feed(Array(bytes[..<cut])) + stream.feed(Array(bytes[cut...]))
        #expect(events == expected, "cut after byte \(cut)")
    }
}

@Test func repliesAndOtherNotificationsAreSkipped() {
    let output = [
        "home /Users/me",
        // A reply's body is never a notification, whatever it looks like.
        "%begin 1759891234 279 0", "%sessions-changed", "home /elsewhere", "%end 1759891234 279 0",
        "%begin 1759891234 280 0", "unknown command: frob", "%error 1759891234 280 0",
        "%window-add @40", "%session-changed $25 cwt-w2", "%extended-output %3 0 : hi",
        "%subscription-changed someone-else $1 - - - : x",
        "%sessions-changed",
        "%exit detached",
    ].map { $0 + "\r\n" }.joined()
    var stream = TmuxWatch.Stream()
    let events = stream.feed(Array(output.utf8))
    #expect(events == [.home("/Users/me"), .sessionsChanged, .exit])
}

@Test func lookIsAnsweredWithEveryPaneAsItStands() {
    let left: Set = ["lhun-test-remark-look"]
    var stream = TmuxWatch.Stream()
    let before = stream.feed(Array(linuxReport.utf8))
    let line = stream.look(leaving: "lhun-test-remark-look")
    // A report tmux took before it read the look shows the session as he left it.
    let waiting = stream.feed(Array(linuxReport.utf8))
    let answer = stream.feed(Array(linuxAnswer.utf8))
    let after = stream.feed(Array(linuxReport.utf8))
    #expect(before == [.panes(linuxPanes, seen: [])])
    #expect(line == TmuxWatch.look)
    #expect(waiting == [.panes(linuxPanes, seen: left)])
    #expect(answer == [.panes(linuxPanes, seen: left)])
    #expect(after == [.panes(linuxPanes, seen: [])])
    // A look tmux turned down ends all the same.
    _ = stream.look(leaving: "lhun-test-remark-look")
    let refusal = ["%begin 1791510839 281 1", "parse error: unknown command: frobnicate", "%error 1791510839 281 1"]
    let refused = stream.feed(Array(refusal.map { $0 + "\r\n" }.joined().utf8))
    let afterRefusal = stream.feed(Array(linuxReport.utf8))
    #expect(refused.isEmpty)
    #expect(afterRefusal == [.panes(linuxPanes, seen: [])])
}

// MARK: What a pane is doing

private func pane(
    _ session: String = "s",
    window: String = "@1",
    index: Int = 0,
    bell: Bool = false,
    shown: Bool = true,
    command: String = "zsh",
    path: String = "",
    alternate: Bool = false,
    progress: PaneReport.Progress = .none,
    title: String = "",
    model: String = "",
    pane: String = "%0"
) -> PaneReport {
    PaneReport(
        session: session, window: window, windowIndex: index, windowBell: bell, isShown: shown, command: command,
        path: path, alternateScreen: alternate, progress: progress, title: title, model: model, pane: pane
    )
}

@Test("A pane's activity", arguments: [
    // omp's title states win over its command.
    (pane(command: "omp", title: "π ⠿ "), PaneReport.Activity.working),
    (pane(command: "omp", title: "π > "), .ready),
    (pane(command: "omp", title: "π ! "), .needsYou),
    (pane(command: "omp", title: "π >"), .ready),
    // omp with title states off, pi (no state in its title), Codex without a title: idle agents.
    (pane(command: "omp", title: "π: s"), .quiet),
    (pane(command: "node", title: "π - "), .quiet),
    // pi says it works only through its progress bar. It runs as node, which on its own would count as work.
    (pane(command: "node", progress: .running, title: "π - "), .working),
    (pane(command: "codex-aarch64-apple-darwin"), .quiet),
    // Claude Code, which runs under its version number.
    (pane(command: "2.1.112", title: "⠿ Fi"), .working),
    (pane(command: "2.1.112", title: "✳ Cl"), .ready),
    // Claude Code through lhun-pty, which tmux names instead.
    (pane(command: "lhun-pty"), .quiet),
    // Anything else in front of the shell is working; shells, remote shells and full-screen programs are not.
    (pane(command: "sleep"), .working),
    (pane(shown: false, command: "sleep"), .quiet),
    (pane(command: "-zsh"), .quiet),
    (pane(command: "/bin/bash"), .quiet),
    (pane(command: "ssh"), .quiet),
    (pane(command: "nvim", alternate: true), .quiet),
    // Progress bars, even behind a shell; an error wants him, even from an agent at its prompt.
    (pane(progress: .running), .working),
    (pane(progress: .paused), .working),
    (pane(command: "omp", progress: .failed, title: "π > "), .needsYou),
])
func paneActivity(pane: PaneReport, expected: PaneReport.Activity) {
    #expect(pane.activity == expected)
}

@Test func sessionTakesItsShownPaneAndMostUrgentActivity() {
    let sessions = SessionReport.sessions(from: [
        pane("a", window: "@1", shown: false, command: "omp", title: "π > "),
        pane("a", window: "@2", index: 3, bell: true, command: "node", path: "/Users/me/src/app", model: "openai-codex/gpt-6-sol"),
        pane("a", window: "@2", index: 3, bell: true, shown: false),
        pane("b", window: "@3", command: "-zsh", path: "/Users/me"),
    ], home: "/Users/me")
    #expect(sessions.map(\.name) == ["a", "b"])
    #expect(sessions[0].command == "node")
    #expect(sessions[0].folder == "~/src/app")
    #expect(sessions[0].model == "openai-codex/gpt-6-sol")
    #expect(sessions[0].shownWindow == "@2")
    #expect(sessions[0].shownIndex == 3)
    #expect(sessions[0].windows == 2)
    #expect(sessions[0].bells == ["@2"])
    #expect(sessions[0].readyWindows == ["@1"])
    #expect(sessions[0].activity == .working)
    #expect(sessions[1].folder == "~")
    #expect(sessions[1].model == "")
    #expect(sessions[1].activity == .quiet)
}

// MARK: Marks

private let elsewhere = SessionRef(host: "mac", name: "elsewhere")

private func ref(_ name: String, host: String = "mac") -> SessionRef {
    SessionRef(host: host, name: name)
}

/// The board under test, held by reference so a call that changes it can sit inside `#expect`. Unless
/// told otherwise, he is looking at another session.
private final class Board {
    private var board = AttentionBoard()

    func update(host: String = "mac", _ panes: PaneReport..., open: SessionRef = elsewhere) -> Bool {
        !board.update(host: host, sessions: SessionReport.sessions(from: panes, home: "/Users/me"), open: open).isEmpty
    }

    func heard(_ name: String, open: SessionRef = elsewhere) -> Bool {
        board.heardBell(ref(name), open: open)
    }

    func opened(_ name: String) {
        board.opened(ref(name))
    }

    func mark(_ name: String, host: String = "mac", open: SessionRef = elsewhere) -> AttentionBoard.Mark? {
        board.mark(ref(name, host: host), open: open)
    }
}

@Test func workingSessionFinishesOffScreen() {
    let board = Board()
    #expect(!board.update(pane("build")))
    #expect(board.mark("build") == nil)
    #expect(!board.update(pane("build", command: "make")))
    #expect(board.mark("build") == .working)
    #expect(board.update(pane("build")))
    #expect(board.mark("build") == .finished)
    board.opened("build")
    #expect(board.mark("build") == nil)
}

@Test func bellFromAShellNeedsHimUntilHeOpensIt() {
    // `sleep 20; printf '\a'` in a session he is not looking at.
    let board = Board()
    _ = board.update(pane("job"))
    _ = board.update(pane("job", command: "sleep"))
    #expect(board.update(pane("job", bell: true)))
    #expect(board.mark("job") == .needsYou)
    // Never on the session on screen.
    #expect(board.mark("job", open: ref("job")) == nil)
    board.opened("job")
    // The flag can outlive his look (a bell in a window he did not switch to); it is seen all the same.
    #expect(!board.update(pane("job", bell: true)))
    #expect(board.mark("job") == nil)
    // Looked at on the Mac, which clears the flag, then rings again: news again.
    _ = board.update(pane("job"))
    #expect(board.update(pane("job", bell: true)))
    #expect(board.mark("job") == .needsYou)
}

@Test func bellFromAnAgentAtItsPromptMeansFinished() {
    let board = Board()
    _ = board.update(pane("agent", command: "omp", title: "π ⠿ "))
    #expect(board.mark("agent") == .working)
    // tmux can report the bell a second before the agent's new title: it reads as a question at first.
    #expect(board.update(pane("agent", bell: true, command: "omp", title: "π ⠿ ")))
    #expect(board.mark("agent") == .needsYou)
    // Then the title says it is at its prompt: finished, and that is not news a second time.
    #expect(!board.update(pane("agent", bell: true, command: "omp", title: "π > ")))
    #expect(board.mark("agent") == .finished)
}

@Test func agentAskingNeedsHimAndAnsweringOnTheMacClearsIt() {
    let board = Board()
    _ = board.update(pane("agent", command: "omp", title: "π ⠿ "))
    #expect(board.update(pane("agent", command: "omp", title: "π ! ")))
    #expect(board.mark("agent") == .needsYou)
    _ = board.update(pane("agent", command: "omp", title: "π ⠿ "))
    #expect(board.mark("agent") == .working)
}

@Test func firstSightMarksOldBellsWithoutNews() {
    let board = Board()
    #expect(!board.update(pane("old", bell: true), pane("busy", command: "make")))
    #expect(board.mark("old") == .needsYou)
    #expect(board.mark("busy") == .working)
}

@Test func whatHappensOnScreenIsSeen() {
    let board = Board()
    let here = ref("here")
    _ = board.update(pane("here", command: "make"), open: here)
    #expect(!board.update(pane("here", window: "@2", bell: true), open: here))
    #expect(board.mark("here", open: here) == nil)
    // He moves on: the bell he was there for, and the build that finished in front of him, stay seen.
    #expect(board.mark("here") == nil)
}

@Test func bellsLhunsOwnTerminalsHear() {
    let board = Board()
    _ = board.update(pane("shell"), pane("agent", window: "@2", command: "omp", title: "π ⠿ "))
    // From a shell: it wants him. A second bell is no news.
    #expect(board.heard("shell"))
    #expect(board.mark("shell") == .needsYou)
    #expect(!board.heard("shell"))
    // From an agent that turns out to be at its prompt: finished.
    #expect(board.heard("agent"))
    _ = board.update(pane("shell"), pane("agent", window: "@2", command: "omp", title: "π > "))
    #expect(board.mark("agent") == .finished)
    // From the session on screen: nothing, then or after he moves on.
    #expect(!board.heard("agent", open: ref("agent")))
    #expect(board.mark("agent") == .finished)
    _ = board.update(pane("shell"), pane("here", window: "@3"))
    #expect(!board.heard("here", open: ref("here")))
    #expect(board.mark("here") == nil)
    board.opened("shell")
    #expect(board.mark("shell") == nil)
}

@Test func sessionsThatEndLoseTheirMarksOnTheirHostOnly() {
    let board = Board()
    _ = board.update(pane("a", bell: true), pane("b", bell: true))
    _ = board.update(host: "server", pane("a", bell: true))
    _ = board.update(pane("b", bell: true))
    #expect(board.mark("a") == nil)
    #expect(board.mark("b") == .needsYou)
    #expect(board.mark("a", host: "server") == .needsYou)
}

@Test func waitHeSawStaysSeenUntilANewOneStarts() {
    let board = Board()
    let asking = pane("agent", command: "omp", title: "π ! ")
    let failed = pane("build", window: "@2", progress: .failed)
    _ = board.update(asking, failed, open: ref("agent"))
    _ = board.update(asking, failed, open: ref("build"))
    // He moves on while the agent still asks and the build still shows its failure: both were seen.
    #expect(!board.update(asking, failed))
    #expect(board.mark("agent") == nil)
    #expect(board.mark("build") == nil)
    // The agent works, then asks again: that question is new.
    _ = board.update(pane("agent", command: "omp", title: "π ⠿ "), failed)
    #expect(board.update(asking, failed))
    #expect(board.mark("agent") == .needsYou)
    #expect(board.mark("build") == nil)
}

// MARK: Leaving a session

/// The two sessions as tmux 3.7c reported them to the watcher, run as Lhûn runs it through a
/// pseudo-terminal on a server of its own, while he left a fake agent's session for the other one. Only
/// the agent's shown command and title changed from one report to the next.
private func traced(_ command: String, _ title: String) -> String {
    "lhun-test-remark-replay-agent\u{1F}@0\u{1F}0\u{1F}0\u{1F}1\u{1F}\(command)\u{1F}/private/var/tmp/lhun-remark"
        + "\u{1F}0\u{1F}hidden\u{1F}\(title)\u{1F}\u{1F}\u{1F}\u{1F}%0\u{1E}"
        + "lhun-test-remark-replay-home\u{1F}@1\u{1F}0\u{1F}0\u{1F}1\u{1F}zsh\u{1F}/private/var/tmp/lhun-remark"
        + "\u{1F}0\u{1F}hidden\u{1F}zsh\u{1F}\u{1F}\u{1F}\u{1F}%1\u{1E}"
}

private func tracedReport(_ command: String, _ title: String) -> String {
    "%subscription-changed lhun $0 - - - : " + traced(command, title) + "\r\n"
}

/// The answer to the look Lhûn wrote as he left, `%begin` and `%end` carrying tmux's time and number.
private func tracedAnswer(_ stamp: String, _ command: String, _ title: String) -> String {
    "%begin \(stamp) 1\r\n" + traced(command, title) + "\r\n%end \(stamp) 1\r\n"
}

/// The replies to the commands the watcher starts with, then its first report.
private let tracedStart = "%begin 1791510642 313 0\r\n%end 1791510642 313 0\r\n"
    + "%begin 1791510642 314 0\r\n%end 1791510642 314 0\r\n"
    + "%session-changed $0 lhun-test-remark-replay-agent\r\n"
    + tracedReport("zsh", "zsh") + "%unlinked-window-renamed @1 zsh\r\n"

private let tracedAgent = "lhun-test-remark-replay-agent"
private let tracedHome = "lhun-test-remark-replay-home"

/// A watcher's output reaching the board as TmuxWatcher, HostLink and AppModel pass it on: leaving a
/// session writes a look, and each report names the sessions it shows as he left them.
private final class Watching {
    private var stream = TmuxWatch.Stream()
    private var board = AttentionBoard()
    private var selection: SessionRef?

    func select(_ name: String) {
        if let left = selection { _ = stream.look(leaving: left.name) }
        selection = ref(name)
        board.opened(ref(name))
    }

    /// The sessions the output made news: the chime plays for them.
    func read(_ output: String) -> [String] {
        stream.feed(Array(output.utf8)).flatMap { event -> [SessionRef] in
            guard case .panes(let panes, let seen) = event else { return [] }
            return board.update(
                host: "mac", sessions: SessionReport.sessions(from: panes, home: "/Users/me"), open: selection,
                seen: Set(seen.map { ref($0) })
            )
        }.map(\.name)
    }

    func mark(_ name: String) -> AttentionBoard.Mark? {
        board.mark(ref(name), open: selection)
    }
}

@Test func finishHeSawIsNoNewsWhenHeLeaves() {
    let watching = Watching()
    #expect(watching.read(tracedStart).isEmpty)
    watching.select(tracedAgent)
    #expect(watching.read(tracedReport("zsh", "π ⠿ ")).isEmpty)
    // The agent finished in front of him. He moved on 0.15 s later, before tmux's next report, which
    // came a second after that and still read as the agent going quiet.
    watching.select(tracedHome)
    #expect(watching.read(tracedAnswer("1791510646 325", "zsh", "π > ")).isEmpty)
    #expect(watching.read(tracedReport("zsh", "π > ")).isEmpty)
    #expect(watching.mark(tracedAgent) == nil)
}

@Test func finishAfterHeLeavesIsNewsWithNothingNewOnScreen() {
    let watching = Watching()
    #expect(watching.read(tracedStart).isEmpty)
    watching.select(tracedAgent)
    #expect(watching.read(tracedReport("zsh", "π ⠿ ")).isEmpty)
    // He moved on while it worked, as its last second and a half of work began.
    watching.select(tracedHome)
    #expect(watching.read(tracedAnswer("1791510655 324", "sleep", "π ⠿ ")).isEmpty)
    #expect(watching.read("%window-renamed @0 sleep\r\n" + tracedReport("sleep", "π ⠿ ")).isEmpty)
    #expect(watching.mark(tracedAgent) == .working)
    // Then it finished, changing nothing on screen but its title: news, so the chime plays, and a mark.
    #expect(watching.read("%window-renamed @0 zsh\r\n" + tracedReport("zsh", "π > ")) == [tracedAgent])
    #expect(watching.mark(tracedAgent) == .finished)
}

// MARK: An agent's ask to open a session beside its own

private func askingPane(_ ask: String) -> String {
    "%subscription-changed lhun $0 - - - : "
        + "agent\u{1F}@0\u{1F}0\u{1F}0\u{1F}1\u{1F}claude\u{1F}/src\u{1F}0\u{1F}\u{1F}✳ Fix it\u{1F}\u{1F}\u{1F}\(ask)\u{1F}%12\u{1E}\r\n"
}

/// The asks the watcher reads from one report of a pane carrying `ask`, or nil when it reads no session.
private func asks(_ ask: String) -> [OpenRequest]? {
    var stream = TmuxWatch.Stream()
    guard case .panes(let panes, _) = stream.feed(Array(askingPane(ask).utf8)).first else { return nil }
    return SessionReport.sessions(from: panes, home: "/Users/me").first?.openRequests
}

@Test("An ask `lhun open` sets names the asking pane, the session and the half, the name kept whole", arguments: [
    ("right %12 build logs", "%12", "build logs", false),
    ("below %3 tests", "%3", "tests", true),
])
func askReadsAsRequest(ask: String, pane: String, session: String, below: Bool) throws {
    let request = try #require(asks(ask)?.first)
    #expect(request.pane == pane)
    #expect(request.session == session)
    #expect(request.below == below)
}

@Test("An ask that names no half, no pane tmux could target, or no session opens nothing", arguments: [
    "", "left %12 logs", "right 12 logs", "right % logs", "right %1;x logs", "right %12", "right %١٢ logs",
])
func malformedAskOpensNothing(ask: String) throws {
    let read = try #require(asks(ask))
    #expect(read.isEmpty)
}

@Test func activityRetainsEachTerminalInTheSameWindow() throws {
    let fields = [
        ["work", "@8", "2", "0", "1", "claude", "/src/api", "0", "", "Fix login", "claude-opus", "state=done:msg=TG9naW4gZml4ZWQ=:records=1:seq=1", "", "%31"],
        ["work", "@8", "2", "0", "0", "omp", "/src/web", "0", "", "π ⠿ ", "gpt-6", "state=blocked:msg=V2hpY2ggYnJhbmNoPw==:records=1:seq=1", "", "%32"],
    ]
    let raw = fields.map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
    let reports = PaneReport.parse(Array(raw.utf8)[...])
    let session = try #require(SessionReport.sessions(from: reports, home: "/Users/me").first)
    #expect(session.panes.map(\.pane) == ["%31", "%32"])
    #expect(session.panes.map(\.path) == ["/src/api", "/src/web"])
    #expect(session.panes.map(\.model) == ["claude-opus", "gpt-6"])
    #expect(session.panes.map { $0.status?.state } == [.done, .blocked])
    #expect(session.panes.map { $0.status?.message } == ["Login fixed", "Which branch?"])
}
