import Observation
import SwiftUI
import UIKit

/// The shared model: hosts, their sessions and what runs in them. One per app, on the main actor;
/// `TerminalSpace` and `SessionTerminal` show it.
///
/// It lists the hosts' sessions as the Lhûn app does: again whenever the app comes back to the front or
/// the network changes. While the terminal space is on screen it hears the scene's phase from there;
/// otherwise it follows the app's own activation, so `hosts` stays current with only a chat on screen.
@MainActor @Observable
public final class Lhun {
    /// Everything the terminal space shows and does.
    let model: AppModel
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Registers LhunKit's fonts, makes or loads this device's key, and attaches the sessions on the cards
    /// the terminal space showed last.
    public init() {
        BundledFonts.register()
        model = AppModel()
        followApp()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Every host, in the Lhûn app's order, with its sessions as its last list has them.
    public var hosts: [LhunHost] {
        model.links.map { link in
            LhunHost(
                id: link.host.id, name: link.host.name, status: LhunHost.Status(link.status),
                sessions: link.sessions.map { model.lhunSession($0, on: link) }
            )
        }
    }

    /// Shows the session in the terminal space, attaching if it is not yet. A session its host does not
    /// list yet opens once a fresh list has it; one it never lists, or a host Lhûn does not know, is named
    /// in a note at the foot of the terminal space.
    public func open(host: String, session: String) {
        let ref = SessionRef(host: host, name: session)
        guard let link = model.link(for: ref) else { return model.note("No host named “\(host)”.") }
        model.open(ref, on: link)
    }

    /// Opens an explicit local Akyl task document or lhun://open?host=&session=. Other URLs are not ours.
    /// Handling a document/link does not mean its task or session has been accepted by the other app.
    public func handle(_ url: URL) -> Bool {
        if url.isFileURL, url.pathExtension.lowercased() == "akyltask" {
            model.importAkylTask(url)
            return true
        }
        guard LhunLink.isLhun(url) else { return false }
        model.open(url)
        return true
    }

    /// Set by the host app. Fired by "Ask Akyl" in the long-press menus of a session's pill in the strip and
    /// of its sidebar row, and in the menu over text selected on a session's screen or in its history.
    /// Unset, a task imported from Akyl uses its native document return; without either, no menu offers it.
    public var onAskAkyl: ((AskAkyl) -> Void)? {
        get { model.onAskAkyl }
        set { model.onAskAkyl = newValue }
    }

    /// This device's key as one authorized_keys line, there from first launch; nil only on a device
    /// without a Secure Enclave, where Lhûn cannot sign in anywhere.
    public var deviceKeyLine: String? {
        model.key?.publicKeyLine
    }

    /// Call after your Mac route installed the key: every host dials again at once, and the terminal space
    /// stops offering its key sheet.
    public func keyInstalled() {
        model.keyInstalled()
    }

    /// Hears the app come to the front, step back and leave the screen, and once, on the next main-queue
    /// turn, whether it is in front already: a model made after the app became active hears no activation.
    private func followApp() {
        let names = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let lhun = self
                MainActor.assumeIsolated { lhun?.appStateChanged() }
            }
        }
        appStateChanged()
    }

    /// Tells the model the app's state as a scene phase, a main-queue turn later, unless a terminal space is
    /// on screen to tell it the scene's own: one that comes on screen at launch speaks first.
    private func appStateChanged() {
        DispatchQueue.main.async { [weak self] in
            let lhun = self
            MainActor.assumeIsolated {
                guard let lhun, !lhun.model.terminalSpaceShown else { return }
                let phase: ScenePhase
                switch UIApplication.shared.applicationState {
                case .active: phase = .active
                case .background: phase = .background
                default: phase = .inactive
                }
                lhun.model.scenePhaseChanged(phase)
            }
        }
    }
}

/// A machine Lhûn signs in to.
public struct LhunHost: Identifiable, Sendable {
    public enum Status: Sendable {
        case online
        case connecting
        /// Unreachable, or refusing this device's key or showing another host key than the one it had.
        case offline
    }

    /// "mac" or "server".
    public let id: String
    public let name: String
    public let status: Status
    public let sessions: [LhunSession]
}

/// A tmux session on one of the hosts.
public struct LhunSession: Identifiable, Hashable, Sendable {
    /// Its host's `LhunHost.id`.
    public let host: String
    public let name: String
    /// Where its shown pane is, with the home folder written as ~.
    public let folder: String
    /// What its shown pane runs: "claude", "omp", "vim"...
    public let program: String?
    /// What a program in its panes last reported of itself, the most urgent report when several do.
    public let state: ProgramState?
    /// The attention mark the strip shows: a program in it waits on you, or failed while you were away.
    public let needsYou: Bool

    public var id: String {
        "\(host).\(name)"
    }
}

/// What a program says of itself through the program status protocol (OSC 7501).
public enum ProgramState: Sendable {
    case working
    /// It waits on you.
    case waiting
    case finished
    case failed
    case idle
}

/// What "Ask Akyl" hands the host app.
public enum AskAkyl: Sendable {
    /// From a session's long-press menu.
    case session(LhunSession)
    /// From the menu over text selected on a session's screen or in its history: the text as a copy takes
    /// it, wrapped rows joined back into their lines.
    case selection(String, in: LhunSession)
}

extension LhunHost.Status {
    init(_ status: HostLink.Status) {
        self = switch status {
        case .online: .online
        case .connecting: .connecting
        case .unreachable, .keyNotAccepted, .hostKeyChanged: .offline
        }
    }
}

extension ProgramState {
    init(_ state: ProgramStatus.State) {
        self = switch state {
        case .idle: .idle
        case .done: .finished
        case .working: .working
        case .error: .failed
        case .blocked: .waiting
        }
    }
}

extension AppModel {
    /// A session its host lists, as the app embedding LhunKit sees it.
    fileprivate func lhunSession(_ session: TmuxSession, on link: HostLink) -> LhunSession {
        let ref = SessionRef(host: link.host.id, name: session.name)
        let state = link.reports.first { $0.name == session.name }?.statuses.first?.status.state
        return LhunSession(
            host: ref.host, name: ref.name, folder: session.folder, program: session.command.isEmpty ? nil : session.command,
            state: state.map(ProgramState.init), needsYou: attention.mark(ref, open: selection) == .needsYou
        )
    }

    /// Hands the session, and the text selected on its screen or in its history, to the app embedding
    /// LhunKit (`Lhun.onAskAkyl`). A session its host no longer lists goes by its name alone.
    func askAkyl(about ref: SessionRef, selection text: String? = nil) {
        if onAskAkyl == nil {
            captureAkylReturn(about: ref, text: text)
            return
        }
        let listed = link(for: ref).flatMap { link in
            link.sessions.first { $0.name == ref.name }.map { lhunSession($0, on: link) }
        }
        let session = listed ?? LhunSession(host: ref.host, name: ref.name, folder: "", program: nil, state: nil, needsYou: false)
        onAskAkyl?(text.map { .selection($0, in: session) } ?? .session(session))
    }
}
