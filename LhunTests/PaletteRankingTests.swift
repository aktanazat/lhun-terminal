import Foundation
import Testing
@testable import LhunKit

/// A palette's rows, as the iPad lists them with a session open, given out of group order.
private let entries = [
    PaletteEntry(id: "compact-layout", group: .settings, title: "Compact Layout", detail: "cards edge to edge, a hairline between"),
    PaletteEntry(id: "layout", group: .settings, title: "Layout", detail: "pills along the top, or a sidebar while sideways"),
    PaletteEntry(id: "open.mac.work", group: .sessions, title: "work", detail: "~/work", keywords: "Mac zsh ~/work"),
    PaletteEntry(id: "open.mac.demo", group: .agents, title: "demo", detail: "~/Developer/demo", keywords: "Mac claude ~/Developer/demo"),
    PaletteEntry(id: "new", group: .commands, title: "New Session", detail: "on Mac"),
    PaletteEntry(id: "split", group: .commands, title: "Split Right", detail: "a new session beside it"),
    PaletteEntry(id: "split-down", group: .commands, title: "Split Down", detail: "a new session below it"),
    PaletteEntry(id: "kill", group: .commands, title: "Kill Session…", detail: ""),
    PaletteEntry(id: "preview.8080", group: .commands, title: "Preview localhost:8080", detail: "on Mac"),
    PaletteEntry(id: "insert-path", group: .files, title: "Insert Path…", detail: "at the cursor"),
]

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// The groups listed, each with its rows' ids in order.
private func listed(_ query: String, in rows: [PaletteEntry] = entries, uses: PaletteUses = PaletteUses(), now: Date = start)
    -> [(PaletteGroup, [String])]
{
    PaletteRanking.sections(rows, query: FuzzyQuery(query), uses: uses, now: now).map { section in
        (section.group, section.hits.map { rows[$0.index].id })
    }
}

private func ids(_ query: String, uses: PaletteUses = PaletteUses(), now: Date = start) -> [String] {
    listed(query, uses: uses, now: now).flatMap(\.1)
}

/// Runs each row once, a minute apart, from `start` on.
private func uses(_ runs: [String]) -> PaletteUses {
    var uses = PaletteUses()
    for (minute, id) in runs.enumerated() {
        uses.ran(id, at: start.addingTimeInterval(Double(minute) * 60))
    }
    return uses
}

@Test func nothingTypedListsEveryGroupInItsOrder() {
    let groups = listed("")
    #expect(groups.map(\.0) == [.sessions, .agents, .commands, .files, .settings])
    #expect(groups.first { $0.0 == .commands }?.1 == ["new", "split", "split-down", "kill", "preview.8080"])
}

@Test func recentListsTheRowsHeRunsMostOnTopAndOnlyThere() {
    let groups = listed("", uses: uses(["kill", "layout", "kill", "kill"]), now: start.addingTimeInterval(3600))
    #expect(groups.map(\.0) == [.recent, .sessions, .agents, .commands, .files, .settings])
    #expect(groups[0].1 == ["kill", "layout"])
    let all = groups.flatMap(\.1)
    #expect(all.count == Set(all).count, "a row listed twice: \(all)")
    #expect(all.count == entries.count)
}

@Test func recentForgetsARunOverFourWeeksOld() {
    let weeks = TimeInterval(7 * 24 * 60 * 60)
    #expect(listed("", uses: uses(["kill"]), now: start.addingTimeInterval(3.9 * weeks)).first?.0 == .recent)
    #expect(listed("", uses: uses(["kill"]), now: start.addingTimeInterval(4.1 * weeks)).first?.0 == .sessions)
}

@Test func aRowListedTwiceShowsOnce() {
    let doubled = entries + [PaletteEntry(id: "kill", group: .commands, title: "Kill Session…", detail: "")]
    for query in ["", "kill", "session"] {
        let all = listed(query, in: doubled).flatMap(\.1)
        #expect(all.count == Set(all).count, "\"\(query)\" listed a row twice: \(all)")
    }
}

@Test("Typing lists each group once, where its best row ranks, so the first row is the best of all", arguments: [
    ("nwsn", "new"),
    ("layout", "layout"),
    ("work", "open.mac.work"),
    ("demo", "open.mac.demo"),
    ("path", "insert-path"),
])
func typingPutsTheBestRowFirst(query: String, best: String) {
    let groups = listed(query)
    #expect(groups.first?.1.first == best)
    #expect(groups.map(\.0).count == Set(groups.map(\.0)).count, "a group listed twice: \(groups.map(\.0))")
}

@Test func aRowHeRunsRisesAboveAnEqualMatch() {
    #expect(ids("split").prefix(2) == ["split-down", "split"])
    #expect(ids("split", uses: uses(["split"])).prefix(2) == ["split", "split-down"])
}

@Test func runsCountOnceInThirtySecondsAndFadeByHalfInTwoWeeks() {
    var uses = PaletteUses()
    uses.ran("kill", at: start)
    uses.ran("kill", at: start.addingTimeInterval(10))
    #expect(uses.weight("kill", at: start) == 1)
    #expect(uses.weight("kill", at: start.addingTimeInterval(PaletteUses.halfLife)) == 0.5)
    uses.ran("kill", at: start.addingTimeInterval(PaletteUses.halfLife))
    #expect(uses.weight("kill", at: start.addingTimeInterval(PaletteUses.halfLife)) == 1.5)
}

@Test func runsAddLessEachTimeUpToForty() {
    let boosts = [1, 5, 1000].map { count in
        uses(Array(repeating: "kill", count: count)).boost("kill", at: start.addingTimeInterval(Double(count) * 60))
    }
    #expect(boosts == [8, 21, 40])
}

@Test func usesSurviveTheirSavedForm() {
    let saved = uses(["kill", "layout", "kill"])
    #expect(PaletteUses(stored: saved.stored) == saved)
    #expect(PaletteUses(stored: "something else") == PaletteUses())
}

@Test("A wrong, missing, extra or swapped letter in a word of the title still finds its row", arguments: [
    ("compsct", "compact-layout"),
    ("sessoin", "kill"),
    ("previwe", "preview.8080"),
    ("localhosr", "preview.8080"),
])
func typos(query: String, row: String) {
    #expect(ids(query).contains(row))
}

@Test func aTitleWithATypoOutranksTheLettersStrewnThroughADetail() {
    // "a new session beside it" holds s, e, s, i, s and the group's name o, n in order; New Session and Kill
    // Session name it, in either order.
    #expect(Set(ids("sesison").prefix(2)) == ["new", "kill"])
}

@Test("A short term, or one holding a digit, is taken as typed", arguments: [
    "kiil",
    "localhosr:8080",
])
func termsTakenAsTyped(query: String) {
    #expect(ids(query).isEmpty)
}

@Test func aTypoMarksTheLettersTheRowHas() throws {
    let row = try #require(entries.first { $0.id == "compact-layout" })
    let hit = PaletteRanking.sections([row], query: FuzzyQuery("compsct"), uses: PaletteUses(), now: start).first?.hits.first
    let read = try #require(hit?.read)
    #expect(FuzzyMatch.positions(read, in: row.words) == Array(0..<7))
}
