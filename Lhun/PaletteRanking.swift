import Foundation

/// The palette's groups, in the order they list while nothing is typed.
enum PaletteGroup: Int, CaseIterable, Sendable {
    /// The rows he runs most, and most lately, on top while nothing is typed.
    case recent
    case sessions
    /// Sessions running a coding agent.
    case agents
    case commands
    case files
    case settings

    var title: String {
        switch self {
        case .recent: "Recent"
        case .sessions: "Sessions"
        case .agents: "Agents"
        case .commands: "Commands"
        case .files: "Files"
        case .settings: "Settings"
        }
    }
}

/// A palette row as its ranking sees it: what it is called, what it says beside that, and its group.
struct PaletteEntry: Sendable {
    let id: String
    let group: PaletteGroup
    /// The title, a space, the detail, a space, the words it is found by but does not show, a space, then
    /// the group's name: what typing matches.
    let words: String
    /// How many UTF-8 bytes of `words` the title takes.
    let titleLength: Int

    init(id: String, group: PaletteGroup, title: String, detail: String, keywords: String = "") {
        self.id = id
        self.group = group
        words = "\(title) \(detail) \(keywords) \(group.title)"
        titleLength = title.utf8.count
    }
}

/// A run of rows in one group, as indices into the entries ranked.
struct PaletteSection: Sendable {
    let group: PaletteGroup
    var hits: [PaletteHit]
}

struct PaletteHit: Sendable {
    let index: Int
    /// What was typed as the row matched it, any typo put right, for marking the letters that matched; nil
    /// while nothing is typed.
    let read: FuzzyQuery?
}

/// Orders the palette's rows in their groups, each row once.
///
/// While nothing is typed, Recent lists the rows he ran most and most lately, then every group follows in
/// its order with the rest of its rows as given. Typing lists the rows that match, best first: the match's
/// score (`NameMatcher`) plus how much he runs the row (`PaletteUses.boost`). Each group stands where its
/// best row ranks, so the first row is the best of all and Return runs it.
enum PaletteRanking {
    static let recentCount = 5

    static func sections(_ entries: [PaletteEntry], query: FuzzyQuery, uses: PaletteUses, now: Date) -> [PaletteSection] {
        var seen = Set<String>()
        guard !query.isEmpty else { return browsing(entries, uses: uses, now: now, seen: &seen) }
        var matcher = NameMatcher()
        var found: [(hit: PaletteHit, group: PaletteGroup, score: Int, length: Int)] = []
        for (index, entry) in entries.enumerated() where seen.insert(entry.id).inserted {
            guard let match = matcher.score(query, in: entry.words, titleLength: entry.titleLength) else { continue }
            found.append((
                PaletteHit(index: index, read: match.read), entry.group,
                match.score + uses.boost(entry.id, at: now), entry.words.utf8.count
            ))
        }
        found.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.hit.index < b.hit.index
        }
        var sections: [PaletteSection] = []
        var place: [PaletteGroup: Int] = [:]
        for row in found {
            if let at = place[row.group] {
                sections[at].hits.append(row.hit)
            } else {
                place[row.group] = sections.count
                sections.append(PaletteSection(group: row.group, hits: [row.hit]))
            }
        }
        return sections
    }

    private static func browsing(_ entries: [PaletteEntry], uses: PaletteUses, now: Date, seen: inout Set<String>) -> [PaletteSection] {
        var groups: [PaletteGroup: [PaletteHit]] = [:]
        var used: [(index: Int, weight: Double)] = []
        for (index, entry) in entries.enumerated() where seen.insert(entry.id).inserted {
            let weight = uses.weight(entry.id, at: now)
            if weight >= PaletteUses.recentFloor { used.append((index, weight)) }
            groups[entry.group, default: []].append(PaletteHit(index: index, read: nil))
        }
        used.sort { a, b in a.weight != b.weight ? a.weight > b.weight : a.index < b.index }
        let recent = used.prefix(recentCount).map(\.index)
        let lifted = Set(recent)
        var sections: [PaletteSection] = []
        if !recent.isEmpty {
            sections.append(PaletteSection(group: .recent, hits: recent.map { PaletteHit(index: $0, read: nil) }))
        }
        for group in PaletteGroup.allCases {
            let hits = (groups[group] ?? []).filter { !lifted.contains($0.index) }
            if !hits.isEmpty { sections.append(PaletteSection(group: group, hits: hits)) }
        }
        return sections
    }
}

/// How much and how lately he has run each palette row, so the rows he runs rise: fsearch's frecency
/// (github.com/noahdunnagan/fsearch). A run adds one to the row's weight, and the weight halves every
/// fourteen days; running the same row again within thirty seconds does not count twice.
struct PaletteUses: Equatable, Sendable {
    private struct Use: Equatable, Sendable {
        var weight: Double
        var at: Date
    }

    private var uses: [String: Use]

    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    static let repeatWindow: TimeInterval = 30
    /// The weight a row needs to be listed under Recent: one run, four weeks ago.
    static let recentFloor = 0.25
    /// The rows remembered; past this the lightest is forgotten.
    static let kept = 64

    /// From what `stored` saved; anything else stored under its key reads as no runs at all.
    init(stored: Any? = nil) {
        let pairs = (stored as? [String: [Double]] ?? [:]).compactMap { id, pair -> (String, Use)? in
            guard pair.count == 2 else { return nil }
            return (id, Use(weight: pair[0], at: Date(timeIntervalSinceReferenceDate: pair[1])))
        }
        uses = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    }

    /// The weights and times, as a property list for the defaults.
    var stored: [String: [Double]] {
        uses.mapValues { [$0.weight, $0.at.timeIntervalSinceReferenceDate] }
    }

    func weight(_ id: String, at now: Date) -> Double {
        guard let use = uses[id] else { return 0 }
        return use.weight * exp2(-max(0, now.timeIntervalSince(use.at)) / Self.halfLife)
    }

    /// What the row's runs add to its score while typing: 12·ln(1 + weight), so a run adds 8, five 21, and
    /// never more than 40, which a better-placed letter outweighs.
    func boost(_ id: String, at now: Date) -> Int {
        Int(min(12 * log1p(weight(id, at: now)), 40))
    }

    mutating func ran(_ id: String, at now: Date) {
        if let use = uses[id], now.timeIntervalSince(use.at) < Self.repeatWindow { return }
        uses[id] = Use(weight: weight(id, at: now) + 1, at: now)
        guard uses.count > Self.kept, let lightest = uses.keys.min(by: { weight($0, at: now) < weight($1, at: now) }) else { return }
        uses[lightest] = nil
    }
}
