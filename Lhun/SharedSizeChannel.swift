import Foundation

/// The control-mode client that follows who else has a session open, while another screen does
/// (`SharedSize` has the commands and how its output reads). It runs on the session's own connection, so
/// it costs no sign-in and ends with it. It asks tmux for the session's clients once it joins and again
/// after each change that can matter, one question at a time, and runs nothing while nothing changes.
@MainActor
final class SharedSizeChannel {
    private let onReport: @MainActor (SharedSize.Report) -> Void
    private let onEnd: @MainActor (SharedSizeChannel) -> Void
    private var stream = SharedSize.Stream()
    private var shell: ShellChannel?
    private var stopped = false
    /// The pid of this device's own client, which the channel prints before tmux starts.
    private var own = ""
    /// The id of the session, once the control client has joined it.
    private var session: String?
    /// What to do with each answer tmux still owes, oldest first.
    private var answers: [@MainActor (_ ok: Bool, _ lines: [String]) -> Void] = []
    /// A question about the clients is out; a change meanwhile asks again once it is answered.
    private var asking = false
    private var askAgain = false

    init(
        reported: @escaping @MainActor (SharedSize.Report) -> Void,
        ended: @escaping @MainActor (SharedSizeChannel) -> Void
    ) {
        onReport = reported
        onEnd = ended
    }

    func start(on connection: SSHConnection, session name: String, client: String) {
        let output: @Sendable ([UInt8]) -> Void = { [weak self] bytes in
            // The main queue keeps output in arrival order; a Task hop does not promise that.
            let channel = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { channel?.receive(bytes) }
            }
        }
        Task {
            do {
                let shell = try await connection.openShell(
                    command: SharedSize.channel(name, client: client), cols: 80, rows: 24, output: output
                )
                if stopped { shell.close() }
                self.shell = shell
                // tmux may have answered the attach before the channel was handed over.
                if askAgain { ask() }
                _ = await shell.end()
            } catch {
                // The channel never opened: the connection under it is gone.
            }
            shell = nil
            let unanswered = answers
            answers = []
            for answer in unanswered { answer(false, []) }
            onEnd(self)
        }
    }

    func stop() {
        stopped = true
        shell?.close()
    }

    /// Sets or clears tmux's `ignore-size` flag on the client named `client`; `done` hears whether tmux
    /// did it.
    func setIgnoresSize(_ ignore: Bool, client: String, done: @escaping @MainActor (Bool) -> Void) {
        send(SharedSize.setIgnoresSize(ignore, client: client)) { ok, _ in done(ok) }
    }

    private func receive(_ bytes: [UInt8]) {
        guard !stopped else { return }
        for event in stream.feed(bytes) {
            switch event {
            case .own(let pid):
                own = pid
            case .attached(let id):
                session = id
                ask()
            case .changed:
                ask()
            case .reply(let lines, let ok):
                guard !answers.isEmpty else { continue }
                answers.removeFirst()(ok, lines)
            case .exit:
                break
            }
        }
    }

    private func ask() {
        guard let session, shell != nil, !asking else {
            askAgain = true
            return
        }
        asking = true
        askAgain = false
        send(SharedSize.listClients(session: session)) { [weak self] ok, lines in
            guard let self else { return }
            asking = false
            if ok, !stopped, let report = SharedSize.report(lines, own: own) { onReport(report) }
            if askAgain { ask() }
        }
    }

    private func send(_ command: String, then answer: @escaping @MainActor (_ ok: Bool, _ lines: [String]) -> Void) {
        guard let shell, !stopped else {
            answer(false, [])
            return
        }
        answers.append(answer)
        shell.write(Array((command + "\n").utf8))
    }
}
