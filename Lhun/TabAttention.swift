import Foundation

struct TabAttention: Identifiable, Equatable {
    let id: SessionRef
    let ref: SessionRef
    let session: TmuxSession
    let mark: AttentionBoard.Mark?
    let status: ProgramStatus?
    private let reportsActivity: Bool

    private init(root: SessionRef, row: SidebarActivity.Row, board: AttentionBoard, open: SessionRef?) {
        id = root
        ref = row.id
        session = row.session
        mark = board.mark(row.id, open: open)
        status = mark == nil ? board.reportedStatus(row.id) : board.status(row.id, open: open)
        reportsActivity = board.reportsActivity(row.id)
    }

    var doing: String {
        if let message = status?.message { return message }
        switch mark {
        case .needsYou: return status?.state == .error ? "Failed" : "Needs you"
        case .finished: return "Finished"
        case .working: return session.task ?? session.command
        case nil:
            switch status?.state {
            case .blocked: return "Needs you"
            case .error: return "Failed"
            case .done: return "Finished"
            case .working, .idle, nil: return session.task ?? session.command
            }
        }
    }

    private var priority: Int {
        switch mark {
        case .needsYou:
            switch status?.state {
            case .blocked: return 92
            case .error: return 91
            default: return 90
            }
        case .finished: return 80
        case .working: return 70
        case nil:
            guard reportsActivity else { return 0 }
            switch status?.state {
            case .blocked: return 6
            case .error: return 5
            case .working: return 4
            case .done: return 3
            case .idle, nil: return 1
            }
        }
    }

    static func summary(
        root: SessionRef, rows: some Sequence<SidebarActivity.Row>, board: AttentionBoard, open: SessionRef?
    ) -> Self? {
        var result: Self?
        for row in rows {
            let candidate = Self(root: root, row: row, board: board, open: open)
            if let current = result, current.priority >= candidate.priority { continue }
            result = candidate
        }
        return result
    }

    static func grouped(
        _ rows: some Sequence<SidebarActivity.Row>, board: AttentionBoard, open: SessionRef?,
        root: (SessionRef) -> SessionRef
    ) -> [Self] {
        var result: [Self] = []
        var positions: [SessionRef: Int] = [:]
        for row in rows {
            let id = root(row.id)
            let candidate = Self(root: id, row: row, board: board, open: open)
            if let index = positions[id] {
                if candidate.priority > result[index].priority { result[index] = candidate }
            } else {
                positions[id] = result.count
                result.append(candidate)
            }
        }
        return result
    }

    static func news(in summaries: some Sequence<Self>) -> AttentionBoard.Mark? {
        var finished = false
        for summary in summaries {
            if summary.mark == .needsYou { return .needsYou }
            if summary.mark == .finished { finished = true }
        }
        return finished ? .finished : nil
    }
}

extension AppModel {
    func tabAttention(_ ref: SessionRef) -> TabAttention? {
        let root = tabRoot(for: ref)
        let rows = tabMembers(root).lazy.compactMap { member -> SidebarActivity.Row? in
            guard let session = self.link(for: member)?.sessions.first(where: { $0.name == member.name }) else { return nil }
            return SidebarActivity.Row(id: member, session: session)
        }
        return TabAttention.summary(root: root, rows: rows, board: attention, open: selection)
    }

    func groupedActivity(matching query: FuzzyQuery) -> [TabAttention] {
        TabAttention.grouped(activity(matching: query), board: attention, open: selection) { tabRoot(for: $0) }
    }

    func tabNews(in refs: some Sequence<SessionRef>) -> AttentionBoard.Mark? {
        TabAttention.news(in: refs.lazy.compactMap { self.tabAttention($0) })
    }
}
