import Foundation

/// The tmux control-mode client behind the session marks and live program names: one per host, on the
/// host's list connection, so it costs no sign-in of its own and ends with that connection. `TmuxWatch`
/// has what it asks tmux for and how its output reads.
@MainActor
final class TmuxWatcher {
    /// Whether tmux has reported anything yet. A watcher that never got that far is not started again
    /// at once, so a host where it cannot run is not retried in a loop.
    private(set) var reported = false

    private let onReports: @MainActor ([SessionReport], Set<String>) -> Void
    private let onSessionsChanged: @MainActor () -> Void
    private let onJoined: @MainActor (String) -> Void
    private let onEnd: @MainActor (TmuxWatcher) -> Void
    private var stream = TmuxWatch.Stream()
    private var home = ""
    private var hostname = ""
    private var shell: ShellChannel?
    private var stopped = false

    init(
        reports: @escaping @MainActor ([SessionReport], Set<String>) -> Void,
        sessionsChanged: @escaping @MainActor () -> Void,
        joined: @escaping @MainActor (String) -> Void,
        ended: @escaping @MainActor (TmuxWatcher) -> Void
    ) {
        onReports = reports
        onSessionsChanged = sessionsChanged
        onJoined = joined
        onEnd = ended
    }

    func start(on connection: SSHConnection) {
        // The task holds the watcher until its channel ends, so `onEnd` always hears of it. The channel's
        // output handler holds it weakly, since the watcher holds the channel.
        Task { [self] in
            do {
                let shell = try await connection.openShell(command: TmuxWatch.command, cols: 80, rows: 24) {
                    [weak self] bytes in
                    // The main queue keeps output in arrival order; a Task hop does not promise that.
                    let watcher = self
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { watcher?.receive(bytes) }
                    }
                }
                if stopped { shell.close() }
                self.shell = shell
                _ = await shell.end()
            } catch {
                // The channel never opened: the connection under it is gone.
            }
            shell = nil
            onEnd(self)
        }
    }

    func stop() {
        stopped = true
        shell?.close()
    }

    /// He left `session`: tmux reports every pane once more, as it stands now, and until it has, what it
    /// reports of that session counts as seen (`TmuxWatch.look`).
    func look(leaving session: String) {
        guard let shell, !stopped else { return }
        shell.write(stream.look(leaving: session))
    }

    private func receive(_ bytes: [UInt8]) {
        guard !stopped else { return }
        for event in stream.feed(bytes) {
            switch event {
            case .home(let folder):
                home = folder
            case .hostname(let name):
                hostname = name
            case .panes(let panes, let seen):
                reported = true
                onReports(SessionReport.sessions(from: panes, home: home, hostname: hostname), seen)
            case .sessionsChanged:
                onSessionsChanged()
            case .clientJoined(let session):
                onJoined(session)
            case .exit:
                break
            }
        }
    }
}
