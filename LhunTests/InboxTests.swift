import Testing
@testable import LhunKit

@Test("Each session's last two lines with words follow its separator, and a banner before the first is no screen")
func lastLinesPerSession() {
    let output = "Welcome to the server\nLast login: today\n"
        + "\u{1E}lhun-test-inbox-build\n"
        + "Test Suite 'All tests' started\n"
        + "✘ excerpt keeps the newest 200 lines\n"
        + "\n"
        + "error:   1 of 48 tests failed   \n"
        + "% \n"
        + "\n\n"
        + "\u{1E}two words\n"
        + "╭──────────────────────────────╮\n"
        + "│ Apply 3 migrations? [y/N]    │\n"
        + "╰──────────────────────────────╯\n"
        // A session that ended between the list and its capture.
        + "\u{1E}gone\n"
    #expect(Tmux.lastLines(output) == [
        "lhun-test-inbox-build": ["✘ excerpt keeps the newest 200 lines", "error: 1 of 48 tests failed"],
        "two words": ["Apply 3 migrations? [y/N]"],
        "gone": [],
    ])
}

@Test("A line keeps its words, without the borders, rules and bare prompts around them", arguments: [
    ("  make   all  ", "make all"),
    ("│ ok │", "ok"),
    ("▌ 42", "42"),
    ("a\tb", "a b"),
    ("────────────", nil),
    ("% ", nil),
    ("$", nil),
    ("", nil),
] as [(String, String?)])
func wordsInLine(line: String, expected: String?) {
    #expect(Tmux.words(in: line[...]) == expected)
}

@Test("Catching up reads the last 200 lines with words")
func excerptKeepsTheNewest() {
    let capture = (1...250).map { "line \($0)\n\n" }.joined()
    let lines = CatchUp.excerpt(capture)
    #expect(lines.count == 200)
    #expect(lines.first == "line 51")
    #expect(lines.last == "line 250")
}

@Test("A summary comes back as at most three plain sentences", arguments: [
    ("You ran the tests. One failed. It waits on you. Then it deploys.", "You ran the tests. One failed. It waits on you."),
    ("- You ran **swift test**.\n- One test failed in `ExcerptTests`.", "You ran swift test. One test failed in ExcerptTests."),
    ("1. The backup finished.\n2) It needs nothing.", "The backup finished. It needs nothing."),
    ("1 of 48 tests failed.", "1 of 48 tests failed."),
    ("you ran rsync and it ended.\nit needs nothing from you.", "You ran rsync and it ended. It needs nothing from you."),
])
func tidiedSummary(reply: String, expected: String) {
    #expect(CatchUp.tidy(reply) == expected)
}
