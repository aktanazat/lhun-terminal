import os
import UIKit

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "actions")

extension AppModel {
    /// Reads each host's ~/.config/lhun/actions.json again; the palette calls this when it opens. A host
    /// with no file, or a broken one, offers no actions, and what was wrong goes to the log, not an alert.
    func loadActions() {
        for link in links {
            Task {
                do {
                    let parsed = SavedAction.parse(try await link.run(Tmux.actionsFile, timeout: .seconds(10)))
                    for problem in parsed.problems {
                        log.error("\(link.host.name, privacy: .public) actions.json: \(problem, privacy: .public)")
                    }
                    actions[link.host.id] = parsed.actions
                } catch {
                    // An unreachable host keeps what it offered last; its session list says it is unreachable.
                    log.info("\(link.host.name, privacy: .public) actions not read: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// The actions the palette offers from one host: those that start a new session from any host, and
    /// those that run in the open session or a new window of it only from that session's host.
    func offeredActions(on link: HostLink) -> [SavedAction] {
        (actions[link.host.id] ?? []).filter { $0.place == .session || selection?.host == link.host.id }
    }

    func run(_ action: SavedAction, on link: HostLink) {
        switch action.place {
        case .session:
            let name = Tmux.sessionName(for: action.title, after: link.sessions)
            perform(on: link) { [self] in
                _ = try await link.run(Tmux.start(action, as: name))
                select(SessionRef(host: link.host.id, name: name))
            }
        case .here, .window:
            guard let ref = selection, ref.host == link.host.id else { return }
            perform(on: link) {
                _ = try await link.run(action.place == .here ? Tmux.run(action, in: ref.name) : Tmux.openWindow(for: action, in: ref.name))
            }
        }
    }

    @discardableResult
    func performAction(_ id: String) -> Bool {
        if id.hasPrefix("tab."), let number = Int(id.dropFirst(4)) {
            let tabs = tabOrder
            guard tabs.indices.contains(number - 1) else { return false }
            selectTab(tabs[number - 1])
            return true
        }
        let dark = selectedTerminal?.view.traitCollection.userInterfaceStyle == .dark
        let catalog = AppActionCatalog(model: self, dark: dark)
        guard let command = catalog.command(id),
              command.isEnabled, command.opens == nil else { return false }
        dispatchAction(command)
        return true
    }

    func dispatchAction(_ command: Command, remember: Bool = false) {
        guard command.isEnabled else { return }
        if remember, command.remembered { ranFromPalette(command.id) }
        command.run()
    }

    func handleActionKey(_ key: UIKey) -> Bool {
        let bindings = ActionBindings.shared
        guard bindings.isPending || !key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]) else { return false }
        let chord: ActionKey?
        if capsLockAsEscape, key.keyCode == .keyboardCapsLock || key.keyCode == .keyboardLockingCapsLock {
            chord = ActionKey("escape")
        } else {
            chord = ActionKey(key)
        }
        guard let chord else { return false }
        switch bindings.receive(chord) {
        case .pass:
            return false
        case .consumed:
            return true
        case let .action(id):
            if !performAction(id), bindings.bindings.contains(where: { $0.actionID == id }) {
                problem = "That action isn't available here."
            }
            return true
        }
    }
}
