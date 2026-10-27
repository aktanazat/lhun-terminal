import Foundation
import Testing
@testable import LhunKit

// MARK: Reading the tap's summary

/// The fields a summary reads into, for comparing whole.
struct Fields: Equatable, Sendable {
    var state: ProgramStatus.State?
    var kind: ProgramStatus.Kind?
    var progress: Int?
    var app: String?
    var title: String?
    var message: String?
    var records: Int
    var seq: String?

    init(
        state: ProgramStatus.State?, kind: ProgramStatus.Kind? = nil, progress: Int? = nil, app: String? = nil,
        title: String? = nil, message: String? = nil, records: Int, seq: String? = nil
    ) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
        self.records = records
        self.seq = seq
    }

    init(_ status: ProgramStatus) {
        self.init(
            state: status.state, kind: status.kind, progress: status.progress, app: status.app, title: status.title,
            message: status.message, records: status.records, seq: status.seq
        )
    }
}

@Test("The tap's summary reads into what the program reports", arguments: [
    ("state=working:records=1", Fields(state: .working, records: 1)),
    (
        "state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1",
        Fields(state: .blocked, kind: .question, message: "Which branch?", records: 1)
    ),
    ("state=done:app=build:records=2:seq=1759891234000000", Fields(state: .done, app: "build", records: 2, seq: "1759891234000000")),
    ("state=error:progress=40:title=QnVpbGQ=:records=1:seq=7", Fields(state: .error, progress: 40, title: "Build", records: 1, seq: "7")),
    // Something reported, and no record is left.
    ("records=0", Fields(state: nil, records: 0)),
    // What does not read is left out, and the rest stands.
    ("state=blocked:kind=nap:records=1", Fields(state: .blocked, records: 1)),
    ("state=working:progress=101:records=1", Fields(state: .working, records: 1)),
    ("state=working:msg=!!!:records=1", Fields(state: .working, records: 1)),
    ("state=working:msg=/w==:records=1", Fields(state: .working, records: 1)),
    ("state=working:msg=ICAKIA==:records=1", Fields(state: .working, records: 1)),
    ("state=idle:color=red:records=1", Fields(state: .idle, records: 1)),
])
func summaryReads(summary: String, expected: Fields) throws {
    let status = try #require(ProgramStatus(summary: summary))
    #expect(Fields(status) == expected)
}

@Test("A summary that does not read, which any program in a pane could set, is none", arguments: [
    "", "nonsense", "state=working", "state=working:records", "state=working:records=x", "state=working:records=-1",
    "state=sleeping:records=1", "records=1",
])
func summaryRejected(summary: String) {
    #expect(ProgramStatus(summary: summary) == nil)
}

@Test("The activity panel receives every report in a pane, with its own waiting reason and progress")
func snapshotKeepsIndividualReports() throws {
    let reports = [
        "id=:state=working:app=omp:progress=42:title=QnVpbGQ=",
        "id=build/approval:state=blocked:kind=permission:app=omp:msg=QXBwcm92ZSBidWlsZA==",
    ].joined(separator: "\n")
    let summary = "state=blocked:records=2:items=\(Data(reports.utf8).base64EncodedString())"
    let status = try #require(ProgramStatus(summary: summary))
    let items = try #require(status.items)
    #expect(items.map(\.id) == ["build/approval", ""])
    #expect(items[0].kind == .permission)
    #expect(items[0].message == "Approve build")
    #expect(items[1].progress == 42)
    #expect(items[1].title == "Build")
    #expect(!status.itemsUnavailable)

    let oversized = try #require(ProgramStatus(summary: "state=blocked:records=2:items=unavailable"))
    #expect(oversized.items == nil)
    #expect(oversized.itemsUnavailable)
    #expect(oversized.state == .blocked)
}

@Test("A message reads as one line he can trust", arguments: [
    ("Which branch?", "Which branch?"),
    ("line one\nline two", "line one line two"),
    ("tab\there", "tab here"),
    ("\u{1B}[31mred", "[31mred"),
    ("a\u{2028}b", "a b"),
    // Bidirectional overrides and isolates could make it read as something else; other invisibles go too.
    ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
    ("\u{2066}isolated\u{2069}", "isolated"),
    ("zero\u{200B}width", "zerowidth"),
    // Joiners build emoji (woman, zero-width joiner, laptop).
    ("\u{1F469}\u{200D}\u{1F4BB} at work", "\u{1F469}\u{200D}\u{1F4BB} at work"),
    ("  padded  ", "padded"),
])
func messageDisarmed(text: String, expected: String) {
    let summary = "state=blocked:msg=\(Data(text.utf8).base64EncodedString()):records=1"
    #expect(ProgramStatus(summary: summary)?.message == expected)
}

// MARK: A pane's activity

private func pane(
    _ session: String = "s",
    window: String = "@1",
    bell: Bool = false,
    shown: Bool = true,
    command: String = "zsh",
    progress: PaneReport.Progress = .none,
    title: String = "",
    status: String? = nil
) -> PaneReport {
    PaneReport(
        session: session, window: window, windowIndex: 0, windowBell: bell, isShown: shown, command: command, path: "",
        alternateScreen: false, progress: progress, title: title, model: "",
        status: status.flatMap(ProgramStatus.init(summary:)), pane: "%\(window.dropFirst())"
    )
}

@Test("A program's own report wins over every guess", arguments: [
    // The record, whatever the title or the command says. A shell's own report counts: the tap drops a
    // program's working and blocked once that program is gone.
    (pane(status: "state=working:records=1"), PaneReport.Activity.working),
    (pane(command: "omp", title: "π > ", status: "state=working:records=1"), .working),
    (pane(command: "omp", title: "π > ", status: "state=blocked:records=1"), .needsYou),
    (pane(command: "omp", title: "π ⠿ ", status: "state=idle:records=1"), .ready),
    (pane(status: "state=done:records=1:seq=1"), .ready),
    (pane(status: "state=error:records=1:seq=1"), .ready),
    // Once a program has reported, the progress bar no longer counts, record or not.
    (pane(progress: .failed, status: "state=idle:records=1"), .ready),
    (pane(progress: .running, status: "records=0"), .quiet),
    (pane(progress: .failed, status: "records=0"), .quiet),
    // With no record left, the title and the program in front count again.
    (pane(command: "omp", title: "π ⠿ ", status: "records=0"), .working),
    (pane(command: "sleep", status: "records=0"), .working),
    // Nothing reported: the guesses as before.
    (pane(progress: .running), .working),
    (pane(progress: .failed), .needsYou),
])
func activityFromStatus(pane: PaneReport, expected: PaneReport.Activity) {
    #expect(pane.activity == expected)
}

@Test func sessionListsItsProgramsMostUrgentFirst() {
    let session = SessionReport.sessions(from: [
        pane(window: "@1", status: "state=done:records=1:seq=5"),
        pane(window: "@2", status: "state=working:records=1"),
        pane(window: "@3", status: "records=0"),
        pane(window: "@4", status: "state=blocked:kind=auth:records=1"),
        pane(window: "@5", status: "state=error:records=1:seq=6"),
        pane(window: "@6", status: "state=done:records=1:seq=8"),
        pane(window: "@7"),
    ], home: "/Users/me")[0]
    #expect(session.statuses.map(\.window) == ["@4", "@5", "@2", "@1", "@6"])
    #expect(session.finishes == ["@1 5", "@5 6", "@6 8"])
}

@Test func sessionNamesTheProgramBehindLhunPtyByItsReport() {
    let sessions = SessionReport.sessions(from: [
        pane("relayed", command: "lhun-pty", status: "state=idle:app=claude-code:records=1"),
        pane("unreported", command: "lhun-pty"),
        pane("direct", command: "2.1.295", status: "state=idle:app=claude-code:records=1"),
    ], home: "/Users/me")
    #expect(sessions.map(\.command) == ["claude-code", "lhun-pty", "2.1.295"])
}

// MARK: Marks from programs

private let elsewhere = SessionRef(host: "mac", name: "elsewhere")

private func ref(_ name: String, host: String = "mac") -> SessionRef {
    SessionRef(host: host, name: name)
}

/// The board under test, held by reference so a call that changes it can sit inside `#expect`. Unless
/// told otherwise, he is looking at another session.
private final class Board {
    var board: AttentionBoard

    init(seenFinishes: [SessionRef: Set<String>] = [:]) {
        board = AttentionBoard(seenFinishes: seenFinishes)
    }

    func update(host: String = "mac", _ panes: PaneReport..., open: SessionRef = elsewhere) -> Bool {
        update(host: host, panes: panes, open: open)
    }

    func update(host: String = "mac", panes: [PaneReport], open: SessionRef = elsewhere) -> Bool {
        !board.update(host: host, sessions: SessionReport.sessions(from: panes, home: "/Users/me"), open: open).isEmpty
    }

    func opened(_ name: String) {
        board.opened(ref(name))
    }

    func mark(_ name: String, open: SessionRef = elsewhere) -> AttentionBoard.Mark? {
        board.mark(ref(name), open: open)
    }

    func status(_ name: String, open: SessionRef = elsewhere) -> ProgramStatus? {
        board.status(ref(name), open: open)
    }
}

@Test("The mark a session's programs give it before he has seen anything", arguments: [
    (["state=working:records=1", "state=error:records=1:seq=1"], AttentionBoard.Mark?.some(.needsYou)),
    (["state=working:records=1", "state=done:records=1:seq=1"], .working),
    (["state=working:records=1", "state=blocked:records=1"], .needsYou),
    (["state=idle:records=1", "state=done:records=1:seq=1"], .finished),
    (["state=idle:records=1"], nil),
    (["records=0"], nil),
])
func markFromPrograms(statuses: [String], expected: AttentionBoard.Mark?) {
    let board = Board()
    _ = board.update(panes: statuses.enumerated().map { pane("s", window: "@\($0.offset)", status: $0.element) })
    #expect(board.mark("s") == expected)
}

@Test func doneShowsUntilSeenThenAgainForANewOne() {
    let board = Board()
    _ = board.update(pane("job", status: "state=working:records=1"))
    #expect(board.update(pane("job", status: "state=done:msg=QnVpbGQ=:records=1:seq=1")))
    #expect(board.mark("job") == .finished)
    #expect(board.status("job")?.message == "Build")
    board.opened("job")
    #expect(board.mark("job") == nil)
    // The same done, reported again, stays seen.
    #expect(!board.update(pane("job", status: "state=done:msg=QnVpbGQ=:records=1:seq=1")))
    #expect(board.mark("job") == nil)
    #expect(board.update(pane("job", status: "state=done:records=1:seq=2")))
    #expect(board.mark("job") == .finished)
    // One that finishes while he looks is seen as it happens.
    #expect(!board.update(pane("job", status: "state=done:records=1:seq=3"), open: ref("job")))
    #expect(board.mark("job") == nil)
}

@Test func errorNeedsHimUntilSeen() {
    let board = Board()
    _ = board.update(pane("job", status: "state=working:records=1"))
    #expect(board.update(pane("job", status: "state=error:msg=QnVpbGQ=:records=1:seq=1")))
    #expect(board.mark("job") == .needsYou)
    #expect(board.status("job")?.state == .error)
    board.opened("job")
    #expect(board.mark("job") == nil)
    #expect(board.status("job") == nil)
}

@Test func blockedNeedsHimForAsLongAsItWaits() {
    let board = Board()
    _ = board.update(pane("agent", status: "state=working:records=1"))
    #expect(board.update(pane("agent", status: "state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1")))
    #expect(board.mark("agent") == .needsYou)
    #expect(board.status("agent")?.message == "Which branch?")
    board.opened("agent")
    #expect(board.mark("agent") == .needsYou)
    #expect(!board.update(pane("agent", status: "state=working:records=1")))
    #expect(board.mark("agent") == .working)
}

@Test func reportedWorkEndingUnsaidIsNoFinish() {
    // A program said it works, then ended without saying more (^C): the tap drops its record.
    let board = Board()
    _ = board.update(pane("job", status: "state=working:records=1"))
    #expect(!board.update(pane("job", status: "records=0")))
    #expect(board.mark("job") == nil)
}

@Test func statusIsTheReportBehindTheMark() {
    let board = Board()
    _ = board.update(
        pane("ask", status: "state=blocked:kind=permission:records=1"),
        pane("busy", window: "@2", status: "state=working:msg=QnVpbGQ=:records=1"),
        // A bell from a program at rest: a finish no report is behind.
        pane("rang", window: "@3", bell: true, status: "state=idle:records=1")
    )
    #expect(board.status("ask")?.kind == .permission)
    #expect(board.status("busy")?.message == "Build")
    #expect(board.mark("rang") == .finished)
    #expect(board.status("rang") == nil)
    #expect(board.status("ask", open: ref("ask")) == nil)
}

@Test func seenFinishesOutliveTheBoard() {
    let first = Board()
    let panes = [
        pane("job", status: "state=done:records=1:seq=1"),
        pane("other", window: "@2", status: "state=error:records=1:seq=2"),
    ]
    _ = first.update(panes: panes)
    first.opened("job")
    let kept = first.board.seenFinishes
    #expect(kept == [ref("job"): ["@1 1"]])
    // Lhûn comes back: the done he saw stays seen, and the error he never saw still wants him.
    let next = Board(seenFinishes: kept)
    #expect(!next.update(panes: panes))
    #expect(next.mark("job") == nil)
    #expect(next.mark("other") == .needsYou)
    #expect(next.update(pane("job", status: "state=done:records=1:seq=3"), panes[1]))
    #expect(next.mark("job") == .finished)
}

@Test func seenFinishesGoWithTheirReports() {
    let board = Board(seenFinishes: [ref("gone"): ["@1 1"], ref("job", host: "server"): ["@1 4"]])
    _ = board.update(pane("job", status: "state=done:records=1:seq=1"))
    board.opened("job")
    // A session the host no longer lists is gone; another host's wait for that host's report.
    #expect(board.board.seenFinishes == [ref("job"): ["@1 1"], ref("job", host: "server"): ["@1 4"]])
    _ = board.update(pane("job", status: "state=working:records=1"))
    #expect(board.board.seenFinishes == [ref("job", host: "server"): ["@1 4"]])
}

// MARK: What he reads and hears

@Test("A mark reads with what the program behind it says", arguments: [
    (AttentionBoard.Mark?.some(.needsYou), "state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1", "needs you, question: Which branch?"),
    (.needsYou, "state=blocked:kind=permission:records=1", "needs you, approval"),
    (.needsYou, "state=blocked:kind=auth:records=1", "needs you, sign-in"),
    (.needsYou, "state=blocked:records=1", "needs you"),
    (.needsYou, "state=error:msg=QnVpbGQ=:records=1:seq=1", "needs you, failed: Build"),
    (.needsYou, "state=error:records=1:seq=1", "needs you, failed"),
    (.finished, "state=done:msg=QnVpbGQ=:records=1:seq=1", "finished, Build"),
    (.working, "state=working:records=1", "working"),
    (.needsYou, "", "needs you"),
    (nil, "state=blocked:kind=question:records=1", ""),
])
@MainActor
func markLabel(mark: AttentionBoard.Mark?, summary: String, expected: String) {
    #expect(AttentionMark.label(mark, status: ProgramStatus(summary: summary)) == expected)
}

@Test("Chimes come at least ten seconds apart", arguments: [
    (nil, 0, true), (0, 9.9, false), (0, 10, true), (0, 60, true),
] as [(Double?, Double, Bool)])
func chimeSpacing(last: Double?, now: Double, due: Bool) {
    let start = ContinuousClock.now
    #expect(Chime.isDue(at: start + .seconds(now), after: last.map { start + .seconds($0) }) == due)
}
