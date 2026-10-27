import Foundation

/// Which sessions want his eyes: a working session spins, a finished one gets a dot, and one waiting on
/// him gets a stronger mark, until he opens it. Fed by each host's watcher and by the bells Lhûn's own
/// terminals hear. The session on screen never shows a mark: whatever happens there, he sees, and it
/// stays seen once he moves on.
///
/// A program that reports its own status (OSC 7501, ProgramStatus) is taken at its word: blocked waits
/// on him for as long as it says so, and a done or an error marks the session until he has seen that
/// one, which then stays seen, across launches too, until the program reports another.
struct AttentionBoard: Equatable {
    enum Mark: Equatable, Sendable {
        case working
        case finished
        case needsYou
    }

    private struct Entry: Equatable {
        var report: SessionReport?
        /// Windows whose bell he has seen: they were flagged when he last had the session open.
        var seenBells: Set<String> = []
        /// Its programs' finishes he has seen, as `SessionReport.finishes` names them.
        var seenFinishes: Set<String> = []
        /// Lhûn's own terminal rang while the session was off screen. tmux keeps no flag for those,
        /// since the bell went straight to an attached client.
        var heard = false
        /// It stopped working while off screen.
        var finished = false
        /// It was waiting on him when he last saw it, by an agent's title or a failed progress bar. That
        /// wait stays seen until it ends; one that starts after is news.
        var seenWaiting = false

        /// A bell means it finished when it came from an agent now waiting at its prompt, and wants him
        /// otherwise. Judged now rather than when it rang, because an agent rings as it finishes and its
        /// new title can reach tmux's next report a second after the bell. A program's error he has not
        /// seen wants him too, and its done is a finish once nothing works.
        var mark: Mark? {
            guard let report else { return heard ? .needsYou : nil }
            var rang = report.bells.subtracting(seenBells)
            if heard { rang.insert(report.shownWindow) }
            let programWaits = report.statuses.contains { $0.status.state == .blocked }
            if programWaits || (report.activity == .needsYou && !seenWaiting) || !rang.isSubset(of: report.readyWindows)
                || unseen(.error) != nil {
                return .needsYou
            }
            if report.activity == .working { return .working }
            if finished || !rang.isEmpty || unseen(.done) != nil { return .finished }
            return nil
        }

        /// The program's report behind the mark, when one is behind it.
        var status: ProgramStatus? {
            guard let report else { return nil }
            switch mark {
            case .needsYou: return report.statuses.first { $0.status.state == .blocked }?.status ?? unseen(.error)
            case .working: return report.statuses.first { $0.status.state == .working }?.status
            case .finished: return unseen(.done)
            case nil: return nil
            }
        }

        /// The most urgent of its programs' finishes in that state that he has not seen.
        private func unseen(_ state: ProgramStatus.State) -> ProgramStatus? {
            report?.statuses.first { $0.status.state == state && $0.finish.map { !seenFinishes.contains($0) } == true }?
                .status
        }

        /// Everything the report shows has been on his screen.
        mutating func seen() {
            seenBells = report?.bells ?? []
            seenFinishes = report?.finishes ?? []
            seenWaiting = report?.activity == .needsYou
            finished = false
        }
    }

    private var entries: [SessionRef: Entry] = [:]
    /// Finishes he saw in an earlier launch, for sessions no report has listed since.
    private var remembered: [SessionRef: Set<String>]

    init(seenFinishes: [SessionRef: Set<String>] = [:]) {
        remembered = seenFinishes
    }

    /// The programs' finishes he has seen, by session, to keep across launches.
    var seenFinishes: [SessionRef: Set<String>] {
        remembered.merging(entries.compactMapValues { $0.seenFinishes.isEmpty ? nil : $0.seenFinishes }) { $1 }
    }

    func mark(_ ref: SessionRef, open: SessionRef?) -> Mark? {
        ref == open ? nil : entries[ref]?.mark
    }

    /// What the program behind the session's mark reports, when a program's report is behind it.
    func status(_ ref: SessionRef, open: SessionRef?) -> ProgramStatus? {
        ref == open ? nil : entries[ref]?.status
    }

    /// A program in the session says what it is doing (`SessionReport.reportsActivity`). Unlike the mark,
    /// it holds on screen and once seen, for as long as the program says so.
    func reportsActivity(_ ref: SessionRef) -> Bool {
        entries[ref]?.report?.reportsActivity == true
    }

    func reportedStatus(_ ref: SessionRef) -> ProgramStatus? {
        entries[ref]?.report?.statuses.first { $0.status.state != .idle }?.status
    }

    /// Takes a host's latest report. Returns the sessions off screen that just finished or began waiting
    /// on him, which is what the chime is for. A session seen for the first time never counts: what
    /// happened before Lhûn looked is marked, not announced. `seen` names sessions he left after tmux
    /// took the report, which reaches Lhûn up to a second late: what it shows of them, he saw.
    mutating func update(
        host: String, sessions reports: [SessionReport], open: SessionRef?, seen: Set<SessionRef> = []
    ) -> [SessionRef] {
        var news: [SessionRef] = []
        var listed = Set<SessionRef>()
        for report in reports {
            let ref = SessionRef(host: host, name: report.name)
            listed.insert(ref)
            let isNew = entries[ref]?.report == nil
            var entry = entries[ref] ?? Entry()
            if isNew, let seen = remembered.removeValue(forKey: ref) { entry.seenFinishes = seen }
            let before = entry.mark
            // A program that said it works says when it is done, so its work ending unsaid is no finish.
            let reportedWorking = entry.report?.statuses.contains { $0.status.state == .working } == true
            if entry.report?.activity == .working, report.activity == .quiet, !reportedWorking { entry.finished = true }
            if report.activity != .needsYou { entry.seenWaiting = false }
            // A flag cleared elsewhere, by looking at the window on the Mac, is no longer a bell he saw,
            // and a finish its program has moved on from is no longer one to keep.
            entry.seenBells.formIntersection(report.bells)
            entry.seenFinishes.formIntersection(report.finishes)
            entry.report = report
            if ref == open || seen.contains(ref) {
                entry.seen()
            } else if !isNew, Self.isNews(from: before, to: entry.mark) {
                news.append(ref)
            }
            entries[ref] = entry
        }
        entries = entries.filter { $0.key.host != host || listed.contains($0.key) }
        remembered = remembered.filter { $0.key.host != host }
        return news
    }

    /// Lhûn's own terminal for a session rang. Returns whether that is news, as `update` does.
    mutating func heardBell(_ ref: SessionRef, open: SessionRef?) -> Bool {
        guard ref != open else { return false }
        var entry = entries[ref] ?? Entry()
        let before = entry.mark
        entry.heard = true
        entries[ref] = entry
        return Self.isNews(from: before, to: entry.mark)
    }

    /// He opened the session, so everything on it counts as seen, the bells its terminal heard too.
    mutating func opened(_ ref: SessionRef) {
        entries[ref]?.seen()
        entries[ref]?.heard = false
    }

    /// News is a session finishing, or starting to wait on him; never one going back to work, and never
    /// a question turning out to be a finish.
    private static func isNews(from before: Mark?, to after: Mark?) -> Bool {
        switch after {
        case .needsYou: before != .needsYou
        case .finished: before != .finished && before != .needsYou
        case .working, nil: false
        }
    }
}
