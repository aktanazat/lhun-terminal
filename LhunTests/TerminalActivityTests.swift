import Testing
@testable import LhunKit

@Test func activityKeepsResultsAndFocusWithTheirTerminal() throws {
    let ref = SessionRef(host: "mac", name: "work")
    let first = PaneReport(
        session: "work", window: "@8", windowIndex: 2, windowBell: false, isShown: true,
        command: "claude", path: "/src/api", alternateScreen: false, progress: .none,
        title: "Fix login", model: "claude-opus",
        status: ProgramStatus(summary: "state=done:msg=TG9naW4gZml4ZWQ=:records=1:seq=1"), pane: "%31"
    )
    let second = PaneReport(
        session: "work", window: "@8", windowIndex: 2, windowBell: false, isShown: false,
        command: "omp", path: "/src/web", alternateScreen: false, progress: .none,
        title: "π ⠿ ", model: "gpt-6",
        status: ProgramStatus(summary: "state=blocked:msg=V2hpY2ggYnJhbmNoPw==:records=1:seq=1"), pane: "%32"
    )
    let rows = [first, second].map {
        TerminalActivity(ref: ref, pane: $0, folder: $0.path, selected: ref)
    }
    #expect(rows.map(\.pane) == ["%31", "%32"])
    #expect(rows.map(\.stateLabel) == ["Done", "Needs You"])
    #expect(rows.map(\.message) == ["Login fixed", "Which branch?"])
    #expect(rows.map(\.isFocused) == [true, false])
    #expect(rows.map(\.folder) == ["/src/api", "/src/web"])
    #expect(rows[0].id != rows[1].id)
    let unfocused = TerminalActivity(ref: ref, pane: first, folder: first.path, selected: nil)
    #expect(unfocused.id == rows[0].id)
    #expect(unfocused.message == "Login fixed")
    #expect(!unfocused.isFocused)
}
