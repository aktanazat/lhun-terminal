import Foundation
import Testing
@testable import LhunKit

@Test("A good file gives every action with its folder and place, \"where\" defaulting to here")
func actionsParse() {
    let parsed = SavedAction.parse("""
    [
      {"title": "Build demo", "command": "swift build", "folder": "~/Developer/demo", "where": "session"},
      {"title": "Update packages", "command": "swift package update", "where": "window"},
      {"title": "Disk space", "command": "df -h", "folder": null}
    ]
    """)
    #expect(parsed.actions == [
        SavedAction(title: "Build demo", command: "swift build", folder: "~/Developer/demo", place: .session),
        SavedAction(title: "Update packages", command: "swift package update", folder: nil, place: .window),
        SavedAction(title: "Disk space", command: "df -h", folder: nil, place: .here),
    ])
    #expect(parsed.problems.isEmpty)
}

@Test("A bad entry is left out with a problem naming it, and the good entries around it stay")
func actionsSkipBadEntries() {
    let parsed = SavedAction.parse("""
    [
      {"title": "Server headroom", "command": "free -h"},
      {"title": "no command"},
      {"title": "Tail", "command": "tail -f log", "where": "tab"},
      "just text",
      {"title": 5, "command": "ls"},
      {"title": "  ", "command": "ls"},
      {"title": "Server logs", "command": "tail -f service.log", "where": "session"}
    ]
    """)
    #expect(parsed.actions.map(\.title) == ["Server headroom", "Server logs"])
    #expect(parsed.problems.map { $0.prefix { $0 != ":" } } == ["entry 2", "entry 3", "entry 4", "entry 5", "entry 6"])
}

@Test("A file that is not a JSON list offers nothing and says so; an empty one offers nothing quietly", arguments: [
    (#"{"title": "x", "command": "y"}"#, 1),
    ("[{\"title\": \"x\", \"command\": \"y\"}", 1),
    ("", 0),
    ("  \n", 0),
    ("[]", 0),
])
func actionsFromAFileThatIsNotAList(text: String, problems: Int) {
    let parsed = SavedAction.parse(text)
    #expect(parsed.actions.isEmpty)
    #expect(parsed.problems.count == problems)
}

@Test("A new session from an action takes the title's words in lowercase, numbered when taken", arguments: [
    ("Server logs", [], "server-logs"),
    ("Server logs", ["server-logs"], "server-logs-2"),
    ("Server logs", ["server-logs", "server-logs-2"], "server-logs-3"),
    // tmux takes no "." or ":" in a name.
    ("v1.2: build", [], "v1-2-build"),
    ("  ", ["1"], "2"),
] as [(String, [String], String)])
func actionSessionName(title: String, taken: [String], expected: String) {
    let sessions = taken.map {
        TmuxSession(name: $0, windows: 1, window: 0, lastActivity: .now, command: "zsh", folder: "~", model: "")
    }
    #expect(Tmux.sessionName(for: title, after: sessions) == expected)
}
