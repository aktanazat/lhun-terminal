import Testing
@testable import LhunKit

private let samplePaths = [
    ".gitignore", "Package.swift", "Resources/Info.plist", "Resources/demo-catalog.md",
    "Sources/Demo/Log.swift", "Sources/Demo/Tools/Sessions.swift",
    "Sources/Demo/Tools/SessionIndex.swift", "Sources/Demo/Tools/SessionRecord.swift",
    "Tests/DemoTests/LogTests.swift", "Tests/DemoTests/SessionsTests.swift",
    "Tests/DemoTests/WatchTests.swift", "Tests/DemoTests/WatchesTests.swift", "Tests/DemoTests/CIWatchTests.swift",
    "scripts/install.sh",
]

@Test("A path matches when every term's letters appear in it in order", arguments: [
    ("log", "Sources/Demo/Log.swift", true),
    ("gol", "Sources/Demo/Log.swift", false),
    ("srclog", "Sources/Demo/Log.swift", true),
    ("logx", "Sources/Demo/Log.swift", false),
    ("tests log", "Tests/DemoTests/LogTests.swift", true),
    ("log tests", "Sources/Demo/Log.swift", false),
])
func matchesInOrder(query: String, path: String, matches: Bool) {
    #expect((FuzzyMatch.score(FuzzyQuery(query), path) != nil) == matches)
}

@Test("A capital letter in the query makes the match case-sensitive", arguments: [
    ("log", "Sources/Demo/Log.swift", true),
    ("Log", "Sources/Demo/Log.swift", true),
    ("LOG", "Sources/Demo/Log.swift", false),
    ("Log", "scripts/log.sh", false),
])
func smartCase(query: String, path: String, matches: Bool) {
    #expect((FuzzyMatch.score(FuzzyQuery(query), path) != nil) == matches)
}

@Test("Ranking puts a word start ahead of a shorter mid-word match, and a run ahead of scattered letters", arguments: [
    ("ap", ["map.swift", "app/main.swift"], ["app/main.swift", "map.swift"]),
    ("pr", ["sprint.md", "demo-prompt.md"], ["demo-prompt.md", "sprint.md"]),
    ("log", ["docs/long/guide.txt", "Sources/Demo/Log.swift"], ["Sources/Demo/Log.swift", "docs/long/guide.txt"]),
])
func rankingPrefersWordStartsAndRuns(query: String, candidates: [String], best: [String]) {
    #expect(FuzzyMatch.rank(FuzzyQuery(query), in: candidates).map { candidates[$0] } == best)
}

@Test("Ranking synthetic paths: best placement first, equal scores shortest first", arguments: [
    ("log", ["Sources/Demo/Log.swift", "Tests/DemoTests/LogTests.swift", "Resources/demo-catalog.md"]),
    ("sess", [
        "Sources/Demo/Tools/Sessions.swift", "Tests/DemoTests/SessionsTests.swift",
        "Sources/Demo/Tools/SessionIndex.swift", "Sources/Demo/Tools/SessionRecord.swift",
    ]),
    ("watch test", ["Tests/DemoTests/WatchTests.swift", "Tests/DemoTests/WatchesTests.swift", "Tests/DemoTests/CIWatchTests.swift"]),
])
func rankingSyntheticPaths(query: String, top: [String]) {
    let ranked = FuzzyMatch.rank(FuzzyQuery(query), in: samplePaths).map { samplePaths[$0] }
    #expect(Array(ranked.prefix(top.count)) == top)
}

@Test("Highlighting marks the letters of the best placement", arguments: [
    ("log", "Sources/Demo/Log.swift", [13, 14, 15]),
    ("demo log", "Sources/Demo/Log.swift", [8, 9, 10, 11, 13, 14, 15]),
    ("logt", "Tests/DemoTests/LogTests.swift", [16, 17, 18, 19]),
])
func highlighting(query: String, path: String, offsets: [Int]) {
    #expect(FuzzyMatch.positions(FuzzyQuery(query), in: path) == offsets)
}
