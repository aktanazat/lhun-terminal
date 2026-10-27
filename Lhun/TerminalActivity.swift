import Foundation

struct TerminalActivity: Identifiable, Equatable {
    let id: String
    let ref: SessionRef
    let pane: String?
    let window: String?
    let program: String
    let model: String
    let title: String
    let folder: String
    let stateLabel: String
    let message: String?
    let isFocused: Bool
    let status: ProgramStatus?

    var reasonLabel: String? {
        status?.state == .blocked ? status?.kind?.label : nil
    }

    var progress: Int? { status?.progress }
    var recordCount: Int? { status?.records }

    init(ref: SessionRef, pane: PaneReport, folder: String, selected: SessionRef?) {
        id = ref.line + "\t" + pane.pane
        self.ref = ref
        self.pane = pane.pane
        window = pane.window
        program = ProgramStatus.disarmed(pane.program)
        model = ProgramStatus.disarmed(pane.model)
        title = pane.task(hostname: "") ?? ""
        self.folder = ProgramStatus.disarmed(folder)
        stateLabel = Self.state(of: pane)
        message = pane.status?.message
        isFocused = selected == ref && pane.isShown
        status = pane.status
    }

    init(ref: SessionRef, session: TmuxSession, selected: SessionRef?) {
        id = ref.line
        self.ref = ref
        pane = nil
        window = nil
        program = ProgramStatus.disarmed(session.command)
        model = ProgramStatus.disarmed(session.model)
        title = session.task ?? ""
        folder = ProgramStatus.disarmed(session.folder)
        stateLabel = ""
        message = nil
        isFocused = selected == ref
        status = nil
    }

    private static func state(of pane: PaneReport) -> String {
        if let state = pane.status?.state {
            return state.label
        }
        return switch pane.ownActivity {
        case .quiet, .ready: "Idle"
        case .working: "Working"
        case .needsYou: "Needs You"
        case .none: ""
        }
    }
}

extension AppModel {
    func terminalActivities(in ref: SessionRef) -> [TerminalActivity] {
        tabMembers(ref).flatMap { member -> [TerminalActivity] in
            guard let link = link(for: member) else { return [] }
            if let report = link.reports.first(where: { $0.name == member.name }) {
                return report.panes.map { pane in
                    TerminalActivity(
                        ref: member, pane: pane,
                        folder: pane.isShown ? report.folder : pane.path,
                        selected: selection
                    )
                }
            }
            guard let session = link.sessions.first(where: { $0.name == member.name }) else { return [] }
            return [TerminalActivity(ref: member, session: session, selected: selection)]
        }
    }

    func focusActivity(_ row: TerminalActivity) {
        guard link(for: row.ref) != nil else { return }
        select(row.ref)
        guard let pane = row.pane, let window = row.window else {
            focusTerminal()
            return
        }
        focusPane(PaneTarget(ref: row.ref, window: window, pane: pane))
    }

    func focusPane(_ target: PaneTarget) {
        guard let link = link(for: target.ref) else { return }
        perform(on: link) { [self] in
            _ = try await link.run(Tmux.selectPane(target.pane, window: target.window, in: target.ref.name))
            if selection == target.ref { focusTerminal() }
        }
    }
}
