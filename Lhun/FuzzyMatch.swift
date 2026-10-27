import Foundation

/// What the path picker searches for: space-separated terms that must all match, each one's letters in
/// order but not necessarily together. A capital letter anywhere makes the search match case exactly;
/// otherwise case is ignored ("smart case", as in fzf).
struct FuzzyQuery: Sendable {
    let text: String
    fileprivate let terms: [[UInt8]]
    fileprivate let caseSensitive: Bool

    init(_ text: String) {
        let caseSensitive = text.contains(where: \.isUppercase)
        self.text = text
        self.caseSensitive = caseSensitive
        terms = text.split(separator: " ").map { term in
            term.utf8.map { caseSensitive ? $0 : folded($0) }
        }
    }

    /// The query that spells `terms`, each already folded unless `caseSensitive`.
    fileprivate init(terms: [[UInt8]], caseSensitive: Bool) {
        text = String(decoding: Array(terms.joined(separator: [UInt8(ascii: " ")])), as: UTF8.self)
        self.terms = terms
        self.caseSensitive = caseSensitive
    }

    var isEmpty: Bool { terms.isEmpty }

    /// True when every match of `longer` is also a match of this query, so ranking `longer` can start
    /// from this query's matches: typing more letters only ever narrows a search.
    func covers(_ longer: FuzzyQuery) -> Bool {
        longer.text.hasPrefix(text)
    }
}

/// fzf's scoring (its v2 algorithm with the path scheme), over UTF-8 bytes. Every matched letter scores
/// 16; letters that start a word, follow a "/", or come right after the previous match earn bonuses,
/// and letters skipped between matches cost a little. The best placement of the letters wins.
enum FuzzyMatch {
    /// The indices of the candidates that match, best first: higher score, then shorter, then earlier
    /// in the list. `pool` limits the search to those indices, such as a shorter query's matches.
    static func rank(_ query: FuzzyQuery, in candidates: [String], pool: [Int]? = nil) -> [Int] {
        var scorer = Scorer()
        var found: [(index: Int, score: Int, length: Int)] = []
        func consider(_ index: Int) {
            var candidate = candidates[index]
            if let score = scorer.score(query, &candidate) {
                found.append((index, score, candidate.utf8.count))
            }
        }
        if let pool {
            for index in pool { consider(index) }
        } else {
            for index in candidates.indices { consider(index) }
        }
        found.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.index < b.index
        }
        return found.map(\.index)
    }

    /// The score of `text`, or nil when some term's letters do not all appear in it in order.
    static func score(_ query: FuzzyQuery, _ text: String) -> Int? {
        var scorer = Scorer()
        var text = text
        return scorer.score(query, &text)
    }

    /// The UTF-8 offsets of the letters the best placement matched, for highlighting; empty when `text`
    /// does not match.
    static func positions(_ query: FuzzyQuery, in text: String) -> [Int] {
        var scorer = Scorer()
        scorer.tracing = true
        let bytes = Array(text.utf8)
        var matched: Set<Int> = []
        for term in query.terms {
            scorer.trace = Trace()
            let found = bytes.withUnsafeBufferPointer { scorer.align(term, $0, caseSensitive: query.caseSensitive) }
            guard found != nil else { return [] }
            matched.formUnion(scorer.trace.walk())
        }
        return matched.sorted()
    }
}

/// fzf's numbers.
private enum Score {
    static let match = 16
    static let gapStart = -3
    static let gapExtension = -1
    /// A cell no placement reaches. Sums with it stay far below `reachable`.
    static let none = Int.min / 2
    static let reachable = Int.min / 4
}

private enum Bonus {
    static let boundary = Score.match / 2
    static let nonWord = Score.match / 2
    static let camel123 = boundary + Score.gapExtension
    static let consecutive = -(Score.gapStart + Score.gapExtension)
    static let firstLetterMultiplier = 2
    /// The path scheme: a word after a space is an ordinary boundary, and one after "/" a little more.
    static let afterSpace = boundary
    static let afterSlash = boundary + 1

    /// fzf's bonus for a letter of `kind` that follows one of `previous`.
    static func at(_ kind: Kind, after previous: Kind) -> Int {
        if kind.rawValue > Kind.nonWord.rawValue {
            switch previous {
            case .white: return afterSpace
            case .delimiter: return afterSlash
            case .nonWord: return boundary
            default: break
            }
        }
        if previous == .lower && kind == .upper || previous != .number && kind == .number {
            return camel123
        }
        switch kind {
        case .nonWord, .delimiter: return nonWord
        case .white: return afterSpace
        default: return 0
        }
    }

    /// Like the next letter of a run: the run keeps its first letter's bonus, unless this letter starts a
    /// stronger word and begins a run of its own. Returns the bonus and the run's first bonus.
    static func continuing(_ own: Int, run: Int) -> (bonus: Int, run: Int) {
        if own >= boundary && own > run { return (own, own) }
        return (max(own, run, consecutive), run)
    }
}

/// fzf's character classes, in its order: everything above `nonWord` can start a word.
private enum Kind: Int {
    case white, nonWord, delimiter, lower, upper, letter, number
}

private let kinds: [Kind] = (0...255).map { value in
    switch UInt8(value) {
    case UInt8(ascii: "a")...UInt8(ascii: "z"): .lower
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): .upper
    case UInt8(ascii: "0")...UInt8(ascii: "9"): .number
    case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), 0x0B, 0x0C: .white
    case UInt8(ascii: "/"): .delimiter
    // Bytes of multi-byte characters count as letters.
    case 0x80...: .letter
    default: .nonWord
    }
}

private func folded(_ byte: UInt8) -> UInt8 {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
}

/// Every row of one placement, kept so the matched letters can be found by walking back from the best
/// place for the last letter.
private struct Trace {
    var start = 0
    var bonus: [Int] = []
    var scores: [[Int]] = []
    var runs: [[Int]] = []

    func walk() -> [Int] {
        guard let last = scores.last else { return [] }
        // The latest of the best places, so ties highlight letters nearer the file name.
        var column = 0
        for index in last.indices where last[index] >= last[column] { column = index }
        var offsets = [start + column]
        for row in stride(from: scores.count - 1, to: 0, by: -1) {
            let here = scores[row][column]
            let diagonal = scores[row - 1][column - 1]
            if diagonal > Score.reachable,
               diagonal + Score.match + Bonus.continuing(bonus[column], run: runs[row - 1][column - 1]).bonus == here {
                column -= 1
                offsets.append(start + column)
                continue
            }
            // Otherwise this letter was reached across a gap, from the best earlier place.
            var from = -1
            var best = Int.min
            for earlier in stride(from: column - 2, through: 0, by: -1) where scores[row - 1][earlier] > Score.reachable {
                let reached = scores[row - 1][earlier] + Score.gapStart + (column - 2 - earlier) * Score.gapExtension
                if reached > best {
                    best = reached
                    from = earlier
                }
            }
            guard from >= 0 else { break }
            column = from
            offsets.append(start + column)
        }
        return offsets
    }
}

/// Reusable rows for placing a term, so ranking thousands of paths allocates them once.
private struct Scorer {
    var tracing = false
    var trace = Trace()
    private var bonus: [Int] = []
    private var scores: [Int] = []
    private var previousScores: [Int] = []
    private var runs: [Int] = []
    private var previousRuns: [Int] = []

    mutating func score(_ query: FuzzyQuery, _ text: inout String) -> Int? {
        text.withUTF8 { bytes in
            var total = 0
            for term in query.terms {
                guard let score = align(term, bytes, caseSensitive: query.caseSensitive) else { return nil }
                total += score
            }
            return total
        }
    }

    /// The best score for one term, or nil when its letters do not all appear in order.
    ///
    /// A cell holds the best score of a placement whose current letter sits at that column. A letter is
    /// reached either right after the previous one, continuing its run, or across a gap of skipped
    /// letters: the first costs `gapStart`, each further one `gapExtension`.
    mutating func align(_ term: [UInt8], _ text: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> Int? {
        let count = term.count
        guard count > 0 else { return 0 }
        guard count <= text.count else { return nil }
        func byte(_ index: Int) -> UInt8 { caseSensitive ? text[index] : folded(text[index]) }

        // A greedy pass rules most candidates out cheaply and bounds the rest: a placement starts no
        // earlier than the first match of the term's first letter and ends no later than the last match
        // of its last letter.
        var start = 0
        var matched = 0
        for index in 0..<text.count where byte(index) == term[matched] {
            if matched == 0 { start = index }
            matched += 1
            if matched == count { break }
        }
        guard matched == count else { return nil }
        var end = text.count - 1
        while byte(end) != term[count - 1] { end -= 1 }
        let width = end - start + 1
        if bonus.count < width {
            bonus = Array(repeating: 0, count: width)
            scores = bonus
            previousScores = bonus
            runs = bonus
            previousRuns = bonus
        }

        // The path scheme treats the start of a path as if it followed a "/".
        var previous = start > 0 ? kinds[Int(text[start - 1])] : .delimiter
        for column in 0..<width {
            let kind = kinds[Int(text[start + column])]
            bonus[column] = Bonus.at(kind, after: previous)
            previous = kind
        }
        // The first letter's bonus counts double.
        for column in 0..<width {
            if byte(start + column) == term[0] {
                previousScores[column] = Score.match + bonus[column] * Bonus.firstLetterMultiplier
                previousRuns[column] = bonus[column]
            } else {
                previousScores[column] = Score.none
            }
        }
        record(start: start, width: width)
        for row in 1..<count {
            let letter = term[row]
            var gap = Score.none
            for column in 0..<width {
                if column >= 2 {
                    gap = max(gap + Score.gapExtension, previousScores[column - 2] + Score.gapStart)
                }
                guard column >= row, byte(start + column) == letter else {
                    scores[column] = Score.none
                    continue
                }
                var best = Score.none
                var run = bonus[column]
                let diagonal = previousScores[column - 1]
                if diagonal > Score.reachable {
                    let next = Bonus.continuing(bonus[column], run: previousRuns[column - 1])
                    best = diagonal + Score.match + next.bonus
                    run = next.run
                }
                let jump = gap + Score.match + bonus[column]
                if jump > best {
                    best = jump
                    run = bonus[column]
                }
                scores[column] = best
                runs[column] = run
            }
            swap(&scores, &previousScores)
            swap(&runs, &previousRuns)
            record(start: start, width: width)
        }
        var best = Score.none
        for column in 0..<width { best = max(best, previousScores[column]) }
        return best > Score.reachable ? best : nil
    }

    private mutating func record(start: Int, width: Int) {
        guard tracing else { return }
        trace.start = start
        trace.bonus = Array(bonus[0..<width])
        trace.scores.append(Array(previousScores[0..<width]))
        trace.runs.append(Array(previousRuns[0..<width]))
    }
}

/// fsearch's ranking (github.com/noahdunnagan/fsearch) for named rows, such as the palette's, on top of
/// fzf's score. A term found among the title's letters scores 30 more than one that reaches into the rest of
/// the row's words. A title that starts with what was typed scores 30 more again, and one that is all of it
/// 100 more. A term of five letters or more not found in the title as typed may be read with a typo, a
/// wrong, extra, missing or swapped letter, as the start of a word of the title; one of eight letters or
/// more, with up to two. Each typo costs 60, so a clean match as good ranks first. A term holding a digit
/// is taken as typed: port 3001 is another port than 3000, not a typo of it.
struct NameMatcher {
    private static let inTitle = 30
    private var scorer = Scorer()
    private var typos = TypoReader()

    /// The score of `words`, which start with a title `titleLength` UTF-8 bytes long, and the query as it
    /// matched them, any typos put right; nil when some term matches neither as typed nor read with a typo.
    mutating func score(_ query: FuzzyQuery, in words: String, titleLength: Int) -> (score: Int, read: FuzzyQuery)? {
        var words = words
        return words.withUTF8 { text in
            let title = UnsafeBufferPointer(rebasing: text[..<titleLength])
            var total = 0
            // The terms as read, once one needed a typo put right.
            var read: [[UInt8]]?
            for (at, term) in query.terms.enumerated() {
                if let score = scorer.align(term, title, caseSensitive: query.caseSensitive) {
                    total += score + Self.inTitle
                    read?.append(term)
                    continue
                }
                let loose = scorer.align(term, text, caseSensitive: query.caseSensitive)
                let typo = typos.reading(term, in: title, caseSensitive: query.caseSensitive).flatMap { typo in
                    scorer.align(typo.letters, title, caseSensitive: query.caseSensitive).map {
                        (letters: typo.letters, score: $0 + Self.inTitle - TypoReader.cost * typo.edits)
                    }
                }
                if let typo, typo.score > loose ?? .min {
                    total += typo.score
                    if read == nil { read = Array(query.terms[..<at]) }
                    read?.append(typo.letters)
                } else if let loose {
                    total += loose
                    read?.append(term)
                } else {
                    return nil
                }
            }
            guard let read else { return (total + Self.titleBonus(query, title), query) }
            return (total, FuzzyQuery(terms: read, caseSensitive: query.caseSensitive))
        }
    }

    /// 100 when the terms, a space between each, spell the whole title; 30 when they spell its start.
    private static func titleBonus(_ query: FuzzyQuery, _ title: UnsafeBufferPointer<UInt8>) -> Int {
        var at = 0
        for (number, term) in query.terms.enumerated() {
            if number > 0 {
                guard at < title.count, title[at] == UInt8(ascii: " ") else { return 0 }
                at += 1
            }
            guard at + term.count <= title.count else { return 0 }
            for letter in term {
                guard (query.caseSensitive ? title[at] : folded(title[at])) == letter else { return 0 }
                at += 1
            }
        }
        return at == title.count ? 100 : 30
    }
}

/// Reads a term with typos for `NameMatcher`, with one table of edits reused across rows.
private struct TypoReader {
    static let cost = 60
    private var cells: [Int] = []

    /// The most edits a term may be read with: one from five letters, two from eight, none with a digit.
    private static func allowed(_ term: [UInt8]) -> Int {
        guard !term.contains(where: { kinds[Int($0)] == .number }) else { return 0 }
        return (term.count >= 5 ? 1 : 0) + (term.count >= 8 ? 1 : 0)
    }

    /// The letters `term` meant: the shortest start of a word of `title` it spells with the fewest edits,
    /// at most `allowed`, a swap of neighbors one edit; the earliest word wins a tie. The word's first
    /// letter must be the term's.
    mutating func reading(_ term: [UInt8], in title: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> (letters: [UInt8], edits: Int)? {
        let limit = Self.allowed(term)
        guard limit > 0 else { return nil }
        func byte(_ index: Int) -> UInt8 { caseSensitive ? title[index] : folded(title[index]) }
        let count = term.count
        // cells[row * width + column]: the edits between the term's first `row` letters and the word's
        // first `column`.
        let width = count + limit + 1
        if cells.count < (count + 1) * width { cells = Array(repeating: 0, count: (count + 1) * width) }
        var best: (start: Int, length: Int, edits: Int)?
        for start in title.indices where byte(start) == term[0] {
            guard start == 0 || kinds[Int(title[start - 1])].rawValue <= Kind.delimiter.rawValue else { continue }
            let length = min(title.count - start, count + limit)
            for column in 0...length { cells[column] = column }
            for row in 1...count {
                cells[row * width] = row
                for column in 1...length {
                    let here = row * width + column, above = here - width
                    let letter = byte(start + column - 1)
                    var edits = min(cells[above] + 1, cells[here - 1] + 1, cells[above - 1] + (term[row - 1] == letter ? 0 : 1))
                    if row > 1, column > 1, term[row - 1] == byte(start + column - 2), term[row - 2] == letter {
                        edits = min(edits, cells[above - width - 2] + 1)
                    }
                    cells[here] = edits
                }
            }
            var spelled = (length: 0, edits: Int.max)
            for column in 1...length where cells[count * width + column] < spelled.edits {
                spelled = (column, cells[count * width + column])
            }
            if spelled.edits <= limit, spelled.edits < best?.edits ?? Int.max {
                best = (start, spelled.length, spelled.edits)
            }
        }
        guard let best else { return nil }
        return ((best.start..<best.start + best.length).map(byte), best.edits)
    }
}
