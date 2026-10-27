import Testing
@testable import LhunKit

// MARK: What an agent is working on

/// What tmux titles a pane with until a program in it titles it: the host's name, as `uname -n` gives it.
private let hostname = "Example-MacBook-Pro-100.local"

/// The task of a session whose one pane, in ~/src/app, runs `command` under `title`, with what a program
/// in it reports of itself as the tap summarizes it.
private func task(_ command: String, title: String, status: String? = nil) -> String? {
    let pane = PaneReport(
        session: "work", window: "@1", windowIndex: 0, windowBell: false, isShown: true, command: command,
        path: "/Users/me/src/app", alternateScreen: false, progress: .none, title: title, model: "",
        status: status.flatMap(ProgramStatus.init(summary:)), pane: "%1"
    )
    return SessionReport.sessions(from: [pane], home: "/Users/me", hostname: hostname)[0].task
}

@Test func taskIsTheReportedTitleElseAnAgentsOwnTitle() {
    // "Build", as the tap keeps a title. Any program may report one.
    #expect(task("make", title: "app: make", status: "state=working:title=QnVpbGQ=:records=1") == "Build")
    #expect(
        task("lhun-pty", title: "✳ Fix login redirect", status: "state=working:app=claude-code:title=QnVpbGQ=:records=1")
            == "Build"
    )
    #expect(task("lhun-pty", title: "✳ Fix login redirect", status: "state=working:app=claude-code:records=1") == "Fix login redirect")
    // Without either the session goes by its program: another program's title names a file or a place,
    // and a shell's may be one an agent left behind.
    #expect(task("vim", title: "✳ Fix login redirect") == nil)
    #expect(task("zsh", title: "✳ Fix login redirect") == nil)
}

@Test func agentBehindTheRelayGoesByTheNameItReports() {
    #expect(task("lhun-pty", title: "✳ Claude Code", status: "state=idle:app=claude-code:records=1") == nil)
}

@Test("An agent's title names its task without its glyph, unless it says no more than which agent runs where", arguments: [
    // Claude Code: ✳ at rest, a spinner frame (folded to ⠿) while it works, its own name until it has a task,
    // and its version for a process name.
    ("claude", "✳ Fix login redirect", "Fix login redirect"),
    ("claude", "⠿ Fix login redirect", "Fix login redirect"),
    ("claude", "✳ Claude Code", nil),
    ("2.1.295", "✳ Fix login redirect", "Fix login redirect"),
    // omp: π, then its state, then the session's name, or its folder's until it has one.
    ("omp", "π > Tune the omp harness", "Tune the omp harness"),
    ("omp", "π ⠿ Tune the omp harness", "Tune the omp harness"),
    ("omp", "π ! Tune the omp harness", "Tune the omp harness"),
    ("omp", "π: Tune the omp harness", "Tune the omp harness"),
    ("omp", "π > app", nil),
    ("omp", "π >", nil),
    // An agent that titles nothing keeps tmux's title, the host's name, or the shell's.
    ("codex", "Example-MacBook-Pro-100.local", nil),
    ("codex", "(Example-MacBook-Pro-100) ~", nil),
    ("codex", "me@Example-MacBook-Pro-100: ~/src/app", nil),
    ("codex", "/Users/me/src/app", nil),
    ("codex", "~/src/app", nil),
    ("codex", "zsh", nil),
    ("codex", "app: codex --yolo", nil),
    ("codex-aarch64-apple-darwin", "codex", nil),
    // A task may start with its folder's name, and what could hide or reorder its text goes.
    ("claude", "✳ App login fix", "App login fix"),
    ("claude", "✳ Fix login\u{202E} redirect", "Fix login redirect"),
] as [(String, String, String?)])
func taskFromAgentTitle(command: String, title: String, expected: String?) {
    #expect(task(command, title: title) == expected)
}

@Test func watcherLearnsTheHostsNameBeforeTmuxStarts() {
    var stream = TmuxWatch.Stream()
    let events = stream.feed(Array("home /Users/me\r\nhostname Example-MacBook-Pro-100.local\r\n".utf8))
    #expect(events == [.home("/Users/me"), .hostname("Example-MacBook-Pro-100.local")])
}
