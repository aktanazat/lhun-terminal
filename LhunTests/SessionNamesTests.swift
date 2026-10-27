import Testing
@testable import LhunKit

// MARK: Two-word session names

/// SplitMix64: the same seed gives the same names, so a failure can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let everyPair = Set(SessionNames.adjectives.flatMap { adjective in SessionNames.nouns.map { "\(adjective)-\($0)" } })

@Test("Each word list has at least 60 words, none twice, all lowercase letters tmux takes in a name",
      arguments: [SessionNames.adjectives, SessionNames.nouns])
func wordList(words: [String]) {
    #expect(words.count >= 60)
    #expect(Set(words).count == words.count, "a word is listed twice")
    #expect(words.filter { !$0.allSatisfy { ("a"..."z").contains($0) } } == [])
}

@Test("A new name is never a taken one, down to the last pair left", arguments: [1, 2, 3, 99] as [UInt64])
func freshNameSkipsTakenNames(seed: UInt64) {
    var generator = SeededGenerator(state: seed)
    let taken = everyPair.subtracting(["quiet-cove"])
    #expect(SessionNames.fresh(avoiding: taken, using: &generator) == "quiet-cove")
}

@Test("With every pair taken, the name gets a number: -2, then -3")
func withEveryPairTakenTheNameIsNumbered() {
    var generator = SeededGenerator(state: 7)
    let second = SessionNames.fresh(avoiding: everyPair, using: &generator)
    #expect(second.hasSuffix("-2") && everyPair.contains(String(second.dropLast(2))), "got \(second)")
    let third = SessionNames.fresh(avoiding: everyPair.union(everyPair.map { "\($0)-2" }), using: &generator)
    #expect(third.hasSuffix("-3") && everyPair.contains(String(third.dropLast(2))), "got \(third)")
}

@Test("Twenty names in a row begin with more than ten different words, not the next pair in line")
func successiveNamesAreSpread() {
    var generator = SeededGenerator(state: 42)
    var taken: Set<String> = []
    for _ in 0..<20 {
        taken.insert(SessionNames.fresh(avoiding: taken, using: &generator))
    }
    let firstWords = Set(taken.map { $0.split(separator: "-")[0] })
    #expect(taken.count == 20)
    #expect(firstWords.count > 10, "20 names began with only \(firstWords.count) different words: \(taken.sorted())")
}
