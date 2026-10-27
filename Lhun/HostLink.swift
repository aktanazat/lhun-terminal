import Foundation
import NIOCore
import NIOSSH
import Observation

/// One host as the session list sees it: whether Lhûn can reach it, and the tmux sessions running there.
///
/// It keeps its own connection for listing and managing sessions, separate from the terminals, so a slow
/// list never stalls typing and a dropped list connection never touches an attached session.
@MainActor @Observable
final class HostLink: Identifiable {
    enum Status: Equatable {
        case connecting
        case online
        case unreachable
        case keyNotAccepted
        case hostKeyChanged
    }

    let host: Host
    private(set) var status: Status = .connecting
    private(set) var sessions: [TmuxSession] = []
    /// What the host's watcher last reported, one per session. Replaced only when something it reports
    /// changed: a program, a folder, a bell, an agent's state, a progress bar, the set of sessions.
    private(set) var reports: [SessionReport] = []
    /// Called after each new report, with the sessions he left after tmux took it (`TmuxWatch.Event`).
    @ObservationIgnored var onReports: (@MainActor (HostLink, Set<String>) -> Void)?
    /// Called when a client comes to a session, attaching to it or switching to it, with its name.
    @ObservationIgnored var onJoined: (@MainActor (HostLink, String) -> Void)?
    @ObservationIgnored var onListed: (@MainActor (HostLink) -> Void)?

    nonisolated var id: String { host.id }

    @ObservationIgnored private let key: DeviceKey
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var dialing: Task<SSHConnection, Error>?
    @ObservationIgnored private var watcher: TmuxWatcher?

    init(host: Host, key: DeviceKey) {
        self.host = host
        self.key = key
    }

    func refresh(timeout: TimeAmount = .seconds(15)) async {
        do {
            var listed = Tmux.parse(try await run(Tmux.list, timeout: timeout))
            // The list reads no titles, and the watcher names a task again only once it changes.
            for index in listed.indices {
                listed[index].task = reports.first { $0.name == listed[index].name }?.task
            }
            sessions = listed
            status = .online
            onListed?(self)
            watch()
        } catch {
            status = Self.status(for: error)
        }
    }

    /// Runs a command on the host, signing in first when there is no live connection. `input`, when
    /// given, is the command's standard input.
    func run(_ command: String, input: Data? = nil, timeout: TimeAmount = .seconds(15)) async throws -> String {
        let connection = try await connected()
        do {
            return try await connection.run(command, input: input, timeout: timeout)
        } catch {
            // A command that ran and failed leaves the connection fine. Anything else means it is gone.
            if case SSHFailure.commandFailed = error { throw error }
            drop(connection)
            throw error
        }
    }

    /// Opens a tunnel to a port on the host's own localhost, on the same connection the session list
    /// uses, so page loads never queue behind a terminal's output.
    func openTunnel(to port: Int, from originator: SocketAddress) async throws -> NIOAsyncChannel<SSHChannelData, SSHChannelData> {
        let connection = try await connected()
        do {
            return try await connection.openTunnel(to: port, from: originator)
        } catch let error as NIOSSHError where error.type == .channelSetupRejected {
            // The host turned down this one tunnel; the connection itself is fine.
            throw PortClosed(port: port, phrase: host.phrase)
        } catch {
            drop(connection)
            throw error
        }
    }

    /// Signs in on a connection of its own, which nothing else uses or closes. The list connection is
    /// dropped whenever the app comes back or the network changes, and a file on its way would go with it.
    func openConnection() async throws -> SSHConnection {
        try await SSHConnection.open(to: host, key: key.privateKey)
    }

    /// Drops the list connection so the next request dials fresh. Used when the network changes, since
    /// an old connection can look open long after the path under it is gone.
    func redial() {
        watcher?.stop()
        watcher = nil
        connection?.close()
        connection = nil
    }

    static func status(for error: Error) -> Status {
        switch error as? SSHFailure {
        case .keyNotAccepted: .keyNotAccepted
        case .hostKeyChanged: .hostKeyChanged
        default: .unreachable
        }
    }

    /// He left the session: the watcher asks tmux how every session stands right now, so a report tmux
    /// took while he was still looking cannot turn what he saw into news.
    func look(leaving name: String) {
        watcher?.look(leaving: name)
    }

    /// Keeps one tmux control-mode client watching every session while the host has any. It starts after
    /// a list that found sessions; once it ends, the list runs again only if it had been reporting.
    private func watch() {
        guard watcher == nil, !sessions.isEmpty, let connection, connection.isActive else { return }
        let watcher = TmuxWatcher(
            reports: { [weak self] in self?.watched($0, seen: $1) },
            sessionsChanged: { [weak self] in self?.relist() },
            joined: { [weak self] session in
                guard let self else { return }
                onJoined?(self, session)
            },
            ended: { [weak self] in self?.watcherEnded($0) }
        )
        self.watcher = watcher
        watcher.start(on: connection)
    }

    /// Each session's program, folder and model go live, and a session the list has not caught up with,
    /// either way, gets the list run again.
    private func watched(_ reports: [SessionReport], seen: Set<String>) {
        self.reports = reports
        let live = Dictionary(reports.map { ($0.name, $0) }) { first, _ in first }
        let updated = sessions.map { session in
            guard let report = live[session.name] else { return session }
            return TmuxSession(
                name: session.name, windows: report.windows, window: report.shownIndex,
                lastActivity: session.lastActivity, command: report.command, folder: report.folder, model: report.model,
                task: report.task
            )
        }
        if updated != sessions { sessions = updated }
        onReports?(self, seen)
        if live.count != sessions.count || sessions.contains(where: { live[$0.name] == nil }) { relist() }
    }

    private func relist() {
        Task { await refresh() }
    }

    private func watcherEnded(_ ended: TmuxWatcher) {
        guard ended === watcher else { return }
        watcher = nil
        if ended.reported { relist() }
    }

    private func drop(_ connection: SSHConnection) {
        connection.close()
        if self.connection == connection { self.connection = nil }
    }

    private func connected() async throws -> SSHConnection {
        if let connection, connection.isActive { return connection }
        if let dialing { return try await dialing.value }
        let task = Task { [host, key] in try await SSHConnection.open(to: host, key: key.privateKey) }
        dialing = task
        defer { dialing = nil }
        let fresh = try await task.value
        connection = fresh
        return fresh
    }
}

extension HostLink {
    /// The sessions whose name, host, program or folder hold the query's letters in order, in list order;
    /// every session for an empty query. The sidebar's filter and the grid's narrow by this.
    func sessions(matching query: FuzzyQuery) -> [TmuxSession] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            FuzzyMatch.score(query, [session.name, host.name, session.command, session.folder].joined(separator: " ")) != nil
        }
    }
}
