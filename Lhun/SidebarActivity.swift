import Foundation

/// The sidebar narrowed to activity, as Rex's activity view has it: only the sessions whose programs say
/// what they are doing (`SessionReport.reportsActivity`) and those with news he has not seen, newest
/// change first across the hosts, so checking on several agents takes one look. A session stays listed
/// while its program says so, seen or not and on screen too; the dot on the view's glyph is for what he
/// has not seen.
enum SidebarActivity {
    /// A session under the name it goes by across hosts.
    struct Row: Identifiable, Equatable {
        let id: SessionRef
        let session: TmuxSession
    }

    /// Of each host's sessions, in the hosts' order, those whose programs say what they are doing and those
    /// marked as finished or needing him, by whatever says so: newest change first. The sort is stable, so
    /// equal times keep the hosts' order and rows never trade places for nothing.
    static func rows(of hosts: [(id: String, sessions: [TmuxSession])], board: AttentionBoard, open: SessionRef?) -> [Row] {
        hosts.flatMap { host in
            host.sessions.map { Row(id: SessionRef(host: host.id, name: $0.name), session: $0) }
        }
        .filter { row in
            let mark = board.mark(row.id, open: open)
            return board.reportsActivity(row.id) || mark == .finished || mark == .needsYou
        }
        .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// What a dot over rows stands for, as VoiceOver reads it: the strongest mark among them, needing him
    /// over a finish. Work is no news, and a mark goes once he has seen what it marks. The view's glyph shows
    /// it for the activity rows, and a folded group's header for the rows folded under it.
    static func news<Rows: Sequence>(in rows: Rows, board: AttentionBoard, open: SessionRef?) -> AttentionBoard.Mark?
    where Rows.Element: Identifiable, Rows.Element.ID == SessionRef {
        let marks = rows.map { board.mark($0.id, open: open) }
        if marks.contains(.needsYou) { return .needsYou }
        return marks.contains(.finished) ? .finished : nil
    }
}

extension AppModel {
    /// The activity view's rows, from every host's sessions that hold the query's letters.
    func activity(matching query: FuzzyQuery) -> [SidebarActivity.Row] {
        SidebarActivity.rows(
            of: links.map { (id: $0.host.id, sessions: $0.sessions(matching: query)) }, board: attention, open: selection
        )
    }
}
