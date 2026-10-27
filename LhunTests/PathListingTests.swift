import Testing
@testable import LhunKit

@Test("A listing gives the folder, its entries folders first and hidden last, and each file with the folders above it")
func listingParses() throws {
    let output = """
    /Users/a/Developer/demo
    /Users/a
    .git/
    .gitignore
    Sources/
    Package.swift
    .build/
    Tests/
    README.md
    /
    Package.swift
    Sources/Demo/Log.swift
    Tests/DemoTests/LogTests.swift

    """
    let listing = try #require(PathListing(output: output))
    #expect(listing.folder == "/Users/a/Developer/demo")
    #expect(listing.home == "/Users/a")
    #expect(listing.entries == ["Sources/", "Tests/", ".build/", "Package.swift", "README.md", ".gitignore"])
    #expect(listing.paths == [
        "Package.swift", "Sources/", "Sources/Demo/", "Sources/Demo/Log.swift",
        "Tests/", "Tests/DemoTests/", "Tests/DemoTests/LogTests.swift",
    ])
    #expect(!listing.isCapped)
}

@Test("The root folder's own \"/\" line is not taken for the line that ends the entries")
func listingOfRoot() throws {
    let listing = try #require(PathListing(output: "/\n/root\nbin/\netc/\n/\n"))
    #expect(listing.folder == "/")
    #expect(listing.entries == ["bin/", "etc/"])
    #expect(listing.paths.isEmpty)
}

@Test("Output without the line that ends the entries is not a listing", arguments: ["", "/Users/a\n", "/Users/a\n/Users/a\nSources/\n"])
func listingRejectsPartialOutput(output: String) {
    #expect(PathListing(output: output) == nil)
}

@Test("A picked path reads from the pane's folder, else from ~, else in full", arguments: [
    ("/Users/a/Developer/demo/Sources/Demo/Log.swift", "/Users/a/Developer/demo", "Sources/Demo/Log.swift"),
    ("/Users/a/Developer/demo/Sources/", "/Users/a/Developer/demo", "Sources/"),
    ("/Users/a/Developer/lhun/README.md", "/Users/a/Developer/demo", "~/Developer/lhun/README.md"),
    // Until the pane's folder is known, paths are spelled from ~.
    ("/Users/a/Developer/demo/Package.swift", nil, "~/Developer/demo/Package.swift"),
    // A folder whose name only starts like home's is outside it.
    ("/Users/ab/notes.md", "/Users/a/Developer/demo", "/Users/ab/notes.md"),
    ("/opt/service/docker-compose.yml", "/Users/a/Developer/demo", "/opt/service/docker-compose.yml"),
    ("/etc/hosts", "/", "etc/hosts"),
] as [(String, String?, String)])
func spelling(path: String, paneFolder: String?, expected: String) {
    #expect(PathListing.spelling(of: path, from: paneFolder, home: "/Users/a") == expected)
}

@Test("A typed path walks from the root, from ~ or from the folder on show, completing each name", arguments: [
    ("", "/Users/a/Developer/demo", true),
    ("/", "/", true),
    ("/private/var/tmp/", "/private/var/tmp", true),
    ("//private//var/", "/private/var", true),
    ("/../", "/", true),
    ("~/", "/Users/a", true),
    ("~/dev/", "/Users/a/Developer", true),
    ("sou/", "/Users/a/Developer/demo/Sources", true),
    ("./Tests/", "/Users/a/Developer/demo/Tests", true),
    ("../lhun/", "/Users/a/Developer/lhun", true),
    // A name nothing matches is taken as typed; the host says whether it exists.
    ("zzz/", "/Users/a/Developer/demo/zzz", true),
    // The walk waits at a folder whose subfolders are not listed yet.
    ("Sources/Demo/", "/Users/a/Developer/demo/Sources", false),
] as [(Substring, String, Bool)])
func walk(typed: Substring, folder: String, finished: Bool) {
    let subfolders = [
        "/": ["Users/", "opt/", "private/"],
        "/private": ["etc/", "var/"],
        "/private/var": ["db/", "tmp/"],
        "/Users/a": ["Desktop/", "Developer/", "Documents/"],
        "/Users/a/Developer": ["demo/", "lhun/"],
        "/Users/a/Developer/demo": ["scripts/", "Sources/", "Tests/"],
    ]
    let walked = PathListing.walk(typed, from: "/Users/a/Developer/demo", home: "/Users/a") { subfolders[$0] }
    #expect(walked.folder == folder)
    #expect(walked.finished == finished)
}

@Test("A path goes in as one shell word: bare when plain, quoted otherwise, with ~ left free to expand", arguments: [
    ("Sources/Demo/Log.swift", "Sources/Demo/Log.swift"),
    ("/opt/service/docker-compose.yml", "/opt/service/docker-compose.yml"),
    ("My Notes/plan v2.md", "'My Notes/plan v2.md'"),
    ("it's here.txt", #"'it'\''s here.txt'"#),
    (#"say "hi".txt"#, #"'say "hi".txt'"#),
    ("$HOME/x", "'$HOME/x'"),
    ("*.swift", "'*.swift'"),
    ("a=b.txt", "'a=b.txt'"),
    ("naïve.txt", "'naïve.txt'"),
    ("~", "~"),
    ("~/Developer/demo/", "~/Developer/demo/"),
    ("~/Library/Mobile Documents/a.md", "~/'Library/Mobile Documents/a.md'"),
    // A leading dash would read as an option.
    ("-rf", "./-rf"),
    ("--help me", "'./--help me'"),
])
func shellWord(path: String, word: String) {
    #expect(Tmux.word(path) == word)
}
