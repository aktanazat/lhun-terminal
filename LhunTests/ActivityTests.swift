import Foundation
import Testing
@testable import LhunKit

// MARK: The sidebar narrowed to activity

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A session's one pane, shown, running `command` under `title` with its progress bar at `progress`, and
/// what a program in it reports of itself as the tap summarizes it.
private func pane(
    _ session: String, command: String = "zsh", bell: Bool = false, title: String = "", progress: PaneReport.Progress = .none,
    status: String? = nil
) -> PaneReport {
    PaneReport(
        session: session, window: "@1", windowIndex: 0, windowBell: bell, isShown: true, command: command, path: "",
        alternateScreen: false, progress: progress, title: title, model: "",
        status: status.flatMap(ProgramStatus.init(summary:)), pane: "%1"
    )
}

/// A host's sessions as its list gives them, in this order, each last changed that many seconds before now.
private func listed(_ ages: KeyValuePairs<String, TimeInterval>) -> [TmuxSession] {
    ages.map {
        TmuxSession(name: $0.key, windows: 1, window: 0, lastActivity: now - $0.value, command: "zsh", folder: "~", model: "")
    }
}

private func ref(_ name: String, host: String = "mac") -> SessionRef {
    SessionRef(host: host, name: name)
}

private func reportsActivity(_ pane: PaneReport) -> Bool {
    SessionReport.sessions(from: [pane], home: "/Users/me")[0].reportsActivity
}

@Test("A program says what it is doing by a report other than idle, else by an agent's title that works or asks", arguments: [
    ("zsh", "", "state=working:records=1", true),
    ("zsh", "", "state=blocked:kind=question:records=1", true),
    ("zsh", "", "state=done:records=1:seq=1", true),
    ("zsh", "", "state=error:records=1:seq=2", true),
    ("zsh", "", "state=idle:records=1", false),
    ("zsh", "", "records=0", false),
    // A report wins over the title.
    ("claude", "⠿ Fix login redirect", "state=idle:records=1", false),
    // omp reports nothing. Its title spins while it works and shows "!" when it asks; at its prompt it says neither.
    ("omp", "π ⠿ Tune the harness", nil, true),
    ("omp", "π ! Which branch?", nil, true),
    ("omp", "π > Tune the harness", nil, false),
    // Claude Code without the relay that lets it report: a spinner frame while it works, ✳ at its prompt.
    ("claude", "⠿ Fix login redirect", nil, true),
    ("claude", "✳ Fix login redirect", nil, false),
    // A program in front of the shell says nothing of itself, and the shell less.
    ("make", "app: make", nil, false),
    ("zsh", "", nil, false),
] as [(String, String, String?, Bool)])
func programSaysWhatItIsDoing(command: String, title: String, status: String?, says: Bool) {
    #expect(reportsActivity(pane("s", command: command, title: title, status: status)) == says)
}

@Test func aProgressBarSaysItsProgramIsWorking() {
    for progress in [PaneReport.Progress.running, .paused, .failed] {
        #expect(reportsActivity(pane("s", command: "rsync", progress: progress)), "\(progress)")
    }
    #expect(!reportsActivity(pane("s", command: "rsync")))
}

@Test func activityListsSessionsWithActivityOrNeedingHimNewestChangeFirst() {
    var board = AttentionBoard()
    let open = ref("open", host: "server")
    _ = board.update(host: "mac", sessions: SessionReport.sessions(from: [
        pane("working", status: "state=working:records=1"),
        pane("blocked", status: "state=blocked:kind=question:records=1"),
        pane("done", status: "state=done:records=1:seq=1"),
        pane("failed", status: "state=error:records=1:seq=2"),
        pane("idle", status: "state=idle:records=1"),
        pane("quiet"),
    ], home: "/Users/me"), open: open)
    _ = board.update(host: "server", sessions: SessionReport.sessions(from: [
        // A shell's bell needs him, though nothing reports.
        pane("bell", bell: true),
        // On screen it shows no mark, but its program still reports.
        pane("open", status: "state=working:records=1"),
    ], home: "/root"), open: open)
    let hosts = [
        (id: "mac", sessions: listed(["working": 60, "blocked": 300, "done": 10, "failed": 1000, "idle": 5, "quiet": 1])),
        (id: "server", sessions: listed(["bell": 300, "open": 20])),
    ]
    // Equal times keep the hosts' order, the Mac's first, whatever the names.
    #expect(SidebarActivity.rows(of: hosts, board: board, open: open).map(\.id) == [
        ref("done"), ref("open", host: "server"), ref("working"), ref("blocked"), ref("bell", host: "server"), ref("failed"),
    ])
}

@Test func aFinishHeHasNotSeenListsTheSessionUntilHeLooks() {
    var board = AttentionBoard()
    let elsewhere = ref("elsewhere")
    let hosts = [(id: "mac", sessions: listed(["build": 10]))]
    func update(_ command: String) {
        _ = board.update(
            host: "mac", sessions: SessionReport.sessions(from: [pane("build", command: command)], home: "/Users/me"), open: elsewhere
        )
    }
    func rows() -> [SessionRef] {
        SidebarActivity.rows(of: hosts, board: board, open: elsewhere).map(\.id)
    }

    // A build in front of the shell says nothing of itself, so it is not listed while it runs.
    update("make")
    #expect(rows().isEmpty)
    // Its end while he is away is news.
    update("zsh")
    #expect(rows() == [ref("build")])
    board.opened(ref("build"))
    #expect(rows().isEmpty)
}

@Test func dotShowsWhileAListedSessionHasNewsHeHasNotSeen() {
    var board = AttentionBoard()
    let elsewhere = ref("elsewhere")
    // The job changed last, so it leads the rows.
    let hosts = [(id: "mac", sessions: listed(["job": 10, "agent": 20]))]
    func update(job: String, agent: String) {
        let panes = [pane("job", status: job), pane("agent", status: agent)]
        _ = board.update(host: "mac", sessions: SessionReport.sessions(from: panes, home: "/Users/me"), open: elsewhere)
    }
    func dot(_ open: SessionRef) -> AttentionBoard.Mark? {
        SidebarActivity.news(in: SidebarActivity.rows(of: hosts, board: board, open: open), board: board, open: open)
    }

    // Work is no news.
    update(job: "state=working:records=1", agent: "state=working:records=1")
    #expect(dot(elsewhere) == nil)
    // A finish he has not seen is.
    update(job: "state=done:records=1:seq=1", agent: "state=working:records=1")
    #expect(dot(elsewhere) == .finished)
    // Once seen it goes, and the session stays listed.
    board.opened(ref("job"))
    #expect(dot(elsewhere) == nil)
    #expect(SidebarActivity.rows(of: hosts, board: board, open: elsewhere).map(\.id) == [ref("job"), ref("agent")])
    // Waiting on him outranks a finish, though the finish leads the rows.
    update(job: "state=done:records=1:seq=2", agent: "state=blocked:records=1")
    #expect(dot(elsewhere) == .needsYou)
    // What is on screen he sees.
    #expect(dot(ref("agent")) == .finished)
}

private func workspaceActivityRows(partnerCommand: String = "omp") -> [SidebarActivity.Row] {
    [
        SidebarActivity.Row(
            id: ref("shell"),
            session: TmuxSession(
                name: "shell", windows: 1, window: 0, lastActivity: now - 10,
                command: "zsh", folder: "~", model: ""
            )
        ),
        SidebarActivity.Row(
            id: ref("agent", host: "server"),
            session: TmuxSession(
                name: "agent", windows: 2, window: 3, lastActivity: now - 60,
                command: partnerCommand, folder: "~/src/api", model: partnerCommand == "omp" ? "gpt-6" : "",
                task: partnerCommand == "omp" ? "Fix login" : nil
            )
        ),
    ]
}

private func activityStatus(_ state: String, message: String, seq: String = "1") -> String {
    "state=\(state):msg=\(Data(message.utf8).base64EncodedString()):records=1:seq=\(seq)"
}

private func workspaceActivityBoard(
    root: String? = nil, partner: String?, partnerCommand: String = "omp", open: SessionRef? = nil
) -> AttentionBoard {
    var board = AttentionBoard()
    _ = board.update(
        host: "mac", sessions: SessionReport.sessions(from: [pane("shell", status: root)], home: "/Users/me"), open: open
    )
    _ = board.update(
        host: "server", sessions: SessionReport.sessions(from: [pane("agent", command: partnerCommand, status: partner)], home: "/root"),
        open: open
    )
    return board
}

@Test("A quiet workspace root shows its partner's attention and message across hosts", arguments: [
    ("blocked", AttentionBoard.Mark.needsYou),
    ("done", .finished),
    ("working", .working),
])
func quietWorkspaceRootShowsPartnerAttention(state: String, expected: AttentionBoard.Mark) throws {
    let rows = workspaceActivityRows()
    let root = rows[0].id
    let board = workspaceActivityBoard(partner: activityStatus(state, message: "Partner"), open: root)
    let summary = try #require(TabAttention.summary(root: root, rows: rows, board: board, open: root))

    #expect(summary.id == root)
    #expect(summary.ref == rows[1].id)
    #expect(summary.session == rows[1].session)
    #expect(summary.mark == expected)
    #expect(summary.status?.message == "Partner")
    #expect(summary.doing == "Partner")
    #expect(TabAttention.news(in: [summary]) == (expected == .working ? nil : expected))
}

@Test("A workspace keeps its most urgent member's mark and message together", arguments: [
    ("working", "done", false, AttentionBoard.Mark.finished),
    ("done", "working", true, .finished),
    ("done", "blocked", false, .needsYou),
    ("blocked", "done", true, .needsYou),
    ("error", "blocked", false, .needsYou),
    ("blocked", "error", true, .needsYou),
    ("working", "working", true, .working),
])
func workspaceAttentionKeepsUrgentMemberFacts(
    rootState: String, partnerState: String, rootWins: Bool, expected: AttentionBoard.Mark
) throws {
    let rows = workspaceActivityRows()
    let board = workspaceActivityBoard(
        root: activityStatus(rootState, message: "Root"), partner: activityStatus(partnerState, message: "Partner")
    )
    let summary = try #require(TabAttention.summary(root: rows[0].id, rows: rows, board: board, open: nil))
    let responsible = rootWins ? rows[0] : rows[1]

    #expect(summary.ref == responsible.id)
    #expect(summary.session == responsible.session)
    #expect(summary.mark == expected)
    #expect(summary.status?.message == (rootWins ? "Root" : "Partner"))
    #expect(summary.doing == (rootWins ? "Root" : "Partner"))
}

@Test("A focused member keeps its reported activity and session facts without an attention mark",
      arguments: ["blocked", "done", "error", "working"])
func focusedWorkspaceMemberKeepsReportedActivity(state: String) throws {
    let rows = workspaceActivityRows()
    let root = rows[0].id
    let partner = rows[1].id
    let board = workspaceActivityBoard(partner: activityStatus(state, message: "Partner"), open: partner)
    let summary = try #require(TabAttention.summary(root: root, rows: rows, board: board, open: partner))
    let filtered = TabAttention.grouped([rows[1]], board: board, open: partner) { _ in root }

    #expect(summary.id == root)
    #expect(summary.ref == partner)
    #expect(summary.session == rows[1].session)
    #expect(summary.mark == nil)
    #expect(summary.status?.state?.rawValue == state)
    #expect(summary.status?.message == "Partner")
    #expect(summary.doing == "Partner")
    #expect(filtered == [summary])
    #expect(TabAttention.news(in: filtered) == nil)
}

@Test("Opening another workspace member does not see a partner's finish", arguments: [
    ("done", AttentionBoard.Mark.finished),
    ("error", .needsYou),
])
func workspaceFinishStaysUnseenUntilItsOwnMemberOpens(state: String, expected: AttentionBoard.Mark) throws {
    let rows = workspaceActivityRows()
    let root = rows[0].id
    let partner = rows[1].id
    let status = activityStatus(state, message: "Partner")
    var board = workspaceActivityBoard(partner: status)
    let before = board
    let initial = try #require(TabAttention.summary(root: root, rows: rows, board: board, open: root))
    #expect(initial.mark == expected)
    #expect(board == before)

    board.opened(root)
    _ = board.update(
        host: "server", sessions: SessionReport.sessions(from: [pane("agent", status: status)], home: "/root"), open: root
    )
    #expect(TabAttention.summary(root: root, rows: rows, board: board, open: root)?.mark == expected)
    #expect(board.seenFinishes[partner] == nil)

    board.opened(partner)
    let seen = try #require(TabAttention.summary(root: root, rows: rows, board: board, open: root))
    #expect(seen.mark == nil)
    #expect(seen.ref == partner)
    #expect(seen.status?.message == "Partner")
    #expect(board.seenFinishes[partner] == ["@1 1"])

    var restored = AttentionBoard(seenFinishes: board.seenFinishes)
    _ = restored.update(
        host: "server", sessions: SessionReport.sessions(from: [pane("agent", status: status)], home: "/root"), open: root
    )
    #expect(TabAttention.summary(root: root, rows: rows, board: restored, open: root)?.mark == nil)
    _ = restored.update(
        host: "server",
        sessions: SessionReport.sessions(from: [pane("agent", status: activityStatus(state, message: "New finish", seq: "2"))], home: "/root"),
        open: root
    )
    let next = try #require(TabAttention.summary(root: root, rows: rows, board: restored, open: root))
    #expect(next.mark == expected)
    #expect(next.status?.message == "New finish")
}

@Test func groupedActivityKeepsResponsibleMemberAndLatestWorkspaceOrder() throws {
    let rows = workspaceActivityRows()
    let root = rows[0].id
    let partner = rows[1].id
    let other = listed(["other": 20])[0]
    let workspaces = WorkspaceStore(selection: root, panes: [root, partner])
    var board = workspaceActivityBoard(
        root: activityStatus("working", message: "Root"), partner: activityStatus("blocked", message: "Partner")
    )
    _ = board.update(
        host: "mac", sessions: SessionReport.sessions(from: [
            pane("shell", status: activityStatus("working", message: "Root")),
            pane("other", status: activityStatus("working", message: "Other")),
        ], home: "/Users/me"), open: nil
    )
    let activity = SidebarActivity.rows(of: [
        (id: "mac", sessions: [rows[0].session, other]),
        (id: "server", sessions: [rows[1].session]),
    ], board: board, open: nil)
    let grouped = TabAttention.grouped(activity, board: board, open: nil) { workspaces.tabRoot(for: $0) }
    let first = try #require(grouped.first)

    #expect(grouped.map(\.id) == [root, ref("other")])
    #expect(first.ref == partner)
    #expect(first.session == rows[1].session)
    #expect(first.mark == .needsYou)
    #expect(first.status?.message == "Partner")
    #expect(TabAttention.news(in: grouped) == .needsYou)
}

@Test func filteredWorkspaceActivityDoesNotSubstituteAnUnmatchedRoot() throws {
    let rows = workspaceActivityRows()
    let root = rows[0].id
    let board = workspaceActivityBoard(
        root: activityStatus("blocked", message: "Root"), partner: activityStatus("working", message: "Partner")
    )
    let filtered = TabAttention.grouped([rows[1]], board: board, open: nil) { _ in root }
    let match = try #require(filtered.first)

    #expect(filtered.map(\.id) == [root])
    #expect(match.ref == rows[1].id)
    #expect(match.session == rows[1].session)
    #expect(match.mark == .working)
    #expect(match.status?.message == "Partner")
}

@Test func aPartnerBellDoesNotBorrowTheRootsProgramMessage() throws {
    let rows = workspaceActivityRows(partnerCommand: "python3")
    let root = rows[0].id
    var board = workspaceActivityBoard(
        root: activityStatus("working", message: "Root"), partner: nil, partnerCommand: "python3"
    )
    let rang = board.heardBell(rows[1].id, open: root)
    #expect(rang)
    let summary = try #require(TabAttention.summary(root: root, rows: rows, board: board, open: root))

    #expect(summary.ref == rows[1].id)
    #expect(summary.session == rows[1].session)
    #expect(summary.mark == .needsYou)
    #expect(summary.status == nil)
    #expect(summary.doing == "Needs you")
}
