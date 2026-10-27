import Testing
@testable import LhunKit

// MARK: A session's windows

/// What `tmux list-windows` printed on the Mac (tmux 3.7c) for Tmux.windows, after a rename that put a
/// space, a colon and a dot in the second window's name; then the same with a tab in a name.
@Test func listedWindowsReadWithTheirIndexProgramNameAndActiveMark() {
    let windows = Tmux.parseWindows("0\t0\tzsh\t\tzsh\n1\t1\tzsh\t\ta b:c.d\n4\t0\tnode\t\tlogs\tand more\n")
    #expect(windows == [
        TmuxWindow(index: 0, name: "zsh", command: "zsh", isActive: false),
        TmuxWindow(index: 1, name: "a b:c.d", command: "zsh", isActive: true),
        TmuxWindow(index: 4, name: "logs\tand more", command: "node", isActive: false),
    ])
}

/// The palette's window rows name Claude Code behind lhun-pty for what it reports, as the pills do.
@Test func listedWindowsNameAProgramBehindLhunPtyByItsReport() {
    let windows = Tmux.parseWindows(
        "0\t1\tlhun-pty\tstate=working:app=claude-code:records=1\tclaude\n1\t0\tlhun-pty\t\tstarting\n"
    )
    #expect(windows.map(\.command) == ["claude-code", "lhun-pty"])
}

@Test func sessionListCarriesTheShownWindowsIndex() {
    let sessions = Tmux.parse("1759900000\t/Users/me\nwork\t3\t2\t1759900000\tnvim\t/Users/me/src\t\t\n")
    #expect(sessions.map(\.windows) == [3])
    #expect(sessions.map(\.window) == [2])
}

/// The first list already has omp's model, so its pill never shows the plain π before the watcher reports.
@Test func sessionListCarriesTheActivePanesModel() {
    let sessions = Tmux.parse(
        "1759900000\t/Users/me\nakyl\t1\t0\t1759900000\tomp\t/Users/me/src\tanthropic/claude-opus-5-5\t\nwork\t1\t0\t1759900000\tzsh\t/Users/me\t\t\n"
    )
    #expect(sessions.map(\.model) == ["anthropic/claude-opus-5-5", ""])
}

@Test func sessionListNamesAProgramBehindLhunPtyByItsReport() {
    let sessions = Tmux.parse(
        "1759900000\t/Users/me\n"
            + "a\t1\t0\t1759900000\tlhun-pty\t/Users/me\t\tstate=blocked:kind=permission:app=claude-code:records=1\n"
            + "b\t1\t0\t1759900000\tlhun-pty\t/Users/me\t\t\n"
            + "c\t1\t0\t1759900000\tzsh\t/Users/me\t\tstate=done:app=build:records=1:seq=7\n"
    )
    #expect(sessions.map(\.command) == ["claude-code", "lhun-pty", "zsh"])
}

// MARK: Filter or create

@Test("Which name typing offers a new session by", arguments: [
    // Nothing matched, or only commands: the name typed.
    ("brave-meadow", false, "brave-meadow"),
    ("copy screen", false, "copy screen"),
    // A session matched: none, so Return opens it.
    ("wor", true, nil),
    // The open session is never listed as a match, but its name is taken.
    ("akyl", false, nil),
    // Blanks around the name are not part of it; blanks alone are no name.
    ("  scratch ", false, "scratch"),
    ("  ", false, nil),
] as [(String, Bool, String?)])
func newSessionName(query: String, sessionMatched: Bool, expected: String?) {
    #expect(FilterOrCreate.name(query, sessions: ["work", "akyl"], sessionMatched: sessionMatched) == expected)
}
