import Foundation

/// A session someone else has open too, in the Mac's terminal for one, keeps that screen's size.
///
/// tmux sizes a window for the client used last (`window-size latest` on both hosts), so attaching here
/// used to reflow the session on every other screen. When a client that sets sizes is already attached,
/// this screen attaches with tmux's `ignore-size` flag instead: tmux leaves the size to the others, and
/// the card shows their window whole, at a smaller font when it has to (TerminalHost). Take clears the
/// flag, so this screen's size wins; Give Back sets it again. Typing on the other screen, or resizing it,
/// takes the size back, since tmux gives it to the client used last, and this screen then lets go of it.
/// When the other screen leaves, this one takes the size by itself. The other screen's client is never
/// touched.
///
/// While another screen has the session open, a control-mode client on the session's own connection
/// (SharedSizeChannel) hears each change to who is attached and to the window's size, and asks tmux for
/// the clients again. A session nobody else has open runs none.
enum SharedSize {
    /// One of the session's tmux clients.
    struct Client: Equatable {
        let pid: String
        let name: String
        let cols: Int
        let rows: Int
        /// When it was last used, in seconds on the host's clock.
        let activity: Int
    }

    /// Who has the session open, and the size of the window it shows.
    struct Report: Equatable {
        /// This screen's own client, when tmux lists it.
        let own: Client?
        /// The clients that set the session's size besides this screen's: neither control clients nor
        /// ones that ignore sizes.
        let others: [Client]
        let windowCols: Int
        let windowRows: Int

        /// The other screen used last, which tmux sizes the window for once this one lets go.
        var latestOther: Client? {
            others.max { $0.activity < $1.activity }
        }
    }

    /// What this screen does about a new report.
    enum Step: Equatable {
        case stay
        /// Show the window at the size another screen set.
        case watch(cols: Int, rows: Int)
        /// Nobody else sets the size any more: this screen takes it back.
        case take
        /// Another screen took the size, by typing or resizing: this one stops setting it and shows the
        /// window at that screen's size.
        case yield(cols: Int, rows: Int)
        /// Nobody else has the session open: nothing to follow.
        case alone
    }

    /// One line per client: pid, whether it is a control client, whether it ignores sizes, its size (a
    /// control client has no height), when it was last used, the size of the window its session shows,
    /// and its name, last.
    static let clientFormat =
        "#{client_pid} #{client_control_mode} #{m:*ignore-size*,#{client_flags}} #{client_width} #{client_height} "
        + "#{client_activity} #{window_width} #{window_height} #{client_name}"

    /// The pid of this device's client for the session, from the file `Tmux.attach` writes, then one line
    /// per client attached to the session.
    static func query(_ name: String, client: String) -> String {
        Tmux.prelude + #"""
        printf 'own %s\n' "$(cat \#(Tmux.pidFile(name, client: client)) 2>/dev/null)"; \
        tmux list-clients -t \#(Tmux.quote("=" + name)) -F '\#(clientFormat)' 2>/dev/null; true
        """#
    }

    /// The control client: prints the pid of this device's client for the session first, then attaches
    /// taking no pane output and leaving sizes alone. The pseudo-terminal stops echoing, so commands
    /// written to it do not come back as lines.
    static func channel(_ name: String, client: String) -> String {
        Tmux.prelude + #"""
        printf 'own %s\n' "$(cat \#(Tmux.pidFile(name, client: client)) 2>/dev/null)"; stty -echo 2>/dev/null; \
        exec tmux -u -C attach-session -t \#(Tmux.quote("=" + name)) -f no-output,ignore-size
        """#
    }

    /// The control client's command for the clients of the session with id `session` ("$12").
    static func listClients(session: String) -> String {
        "list-clients -t '\(session)' -F '\(clientFormat)'"
    }

    /// The control client's command that sets or clears `ignore-size` on the client named `client`.
    static func setIgnoresSize(_ ignore: Bool, client: String) -> String {
        "refresh-client -t \(Tmux.quote(client)) -f \(ignore ? "ignore-size" : "'!ignore-size'")"
    }

    /// Reads `clientFormat` lines. `own` is the pid of this device's client; any other client that is not
    /// a control client and does not ignore sizes sets the size. Nil when no line reads.
    static func report(_ lines: [String], own: String) -> Report? {
        var mine: Client?
        var others: [Client] = []
        var window: (cols: Int, rows: Int)?
        for line in lines {
            let field = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
            guard field.count == 9, let windowCols = Int(field[6]), let windowRows = Int(field[7]) else { continue }
            window = (windowCols, windowRows)
            let client = Client(
                pid: String(field[0]), name: String(field[8]), cols: Int(field[3]) ?? 0, rows: Int(field[4]) ?? 0,
                activity: Int(field[5]) ?? 0
            )
            if client.pid == own {
                mine = client
            } else if field[1] == "0", field[2] == "0" {
                others.append(client)
            }
        }
        guard let window else { return nil }
        return Report(own: mine, others: others, windowCols: window.cols, windowRows: window.rows)
    }

    /// Reads `query`'s output: the size of the session's window when another screen that sets sizes has
    /// it open, nil when nobody else does.
    static func othersWindow(in output: String) -> (cols: Int, rows: Int)? {
        var lines = output.split(separator: "\n").map(String.init)
        guard let first = lines.first, first.hasPrefix("own") else { return nil }
        lines.removeFirst()
        guard let report = report(lines, own: String(first.dropFirst(4))), !report.others.isEmpty else { return nil }
        return (report.windowCols, report.windowRows)
    }

    /// The size of the window the session shows, whoever sized it, as one line: width, then height.
    /// Nothing when there is no such session. A chat card's terminal opens at it (`TerminalModel.watchesOnly`).
    static func windowQuery(_ name: String) -> String {
        Tmux.prelude + "tmux display -p -t \(Tmux.quote("=" + name + ":")) '#{window_width} #{window_height}' 2>/dev/null; true"
    }

    /// Reads `windowQuery`'s output from its last line, past anything a login script printed first.
    static func window(in output: String) -> (cols: Int, rows: Int)? {
        let field = output.split(separator: "\n").last?.split(separator: " ") ?? []
        guard field.count == 2, let cols = Int(field[0]), let rows = Int(field[1]), cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    /// What to do about `report` while this screen watches, or sets the size and has sent tmux `sent`.
    static func step(watching: Bool, sent: (cols: Int, rows: Int), report: Report) -> Step {
        // tmux does not list this screen's client: it is still on its way, or already gone.
        guard let own = report.own else { return .stay }
        if report.others.isEmpty { return watching ? .take : .alone }
        if watching { return .watch(cols: report.windowCols, rows: report.windowRows) }
        // tmux has this screen's latest size, and still the window has another: a screen used since got it.
        let window = (cols: report.windowCols, rows: report.windowRows)
        if (own.cols, own.rows) == sent, window != sent { return .yield(cols: window.cols, rows: window.rows) }
        return .stay
    }

    enum Event: Equatable {
        /// The pid of this device's client for the session, printed before tmux starts; empty when none.
        case own(String)
        /// The control client joined the session with this id.
        case attached(String)
        /// tmux's answer to a command this client sent: its lines, and whether tmux carried it out.
        case reply([String], ok: Bool)
        /// Something that can change who sets the size, or the size.
        case changed
        /// tmux let the client go.
        case exit
    }

    /// Splits the control client's output into events. It arrives through a pseudo-terminal in arbitrary
    /// chunks, so lines end in "\r\n" and a chunk can stop in the middle of a line or of a character.
    /// Notifications come for every session on the host; each one that can matter is passed on, and the
    /// clients asked for again settle whether it did.
    struct Stream {
        private var pending: [UInt8] = []
        /// The lines of an answer to this client, until it ends.
        private var answer: [String]?
        /// Inside an answer to someone else: the attach itself.
        private var inOtherAnswer = false

        private static let changes = ["%layout-change ", "%session-window-changed ", "%client-detached ", "%client-session-changed "]

        mutating func feed(_ bytes: [UInt8]) -> [Event] {
            pending += bytes
            var events: [Event] = []
            var start = 0
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                var line = pending[start..<newline]
                if line.last == 0x0D { line.removeLast() }
                if let event = event(for: String(decoding: line, as: UTF8.self)) { events.append(event) }
                start = newline + 1
            }
            pending.removeFirst(start)
            return events
        }

        private mutating func event(for line: String) -> Event? {
            let ends = line.hasPrefix("%end ") || line.hasPrefix("%error ")
            if let lines = answer {
                guard ends else {
                    answer = lines + [line]
                    return nil
                }
                answer = nil
                return .reply(lines, ok: line.hasPrefix("%end "))
            }
            if inOtherAnswer {
                if ends { inOtherAnswer = false }
                return nil
            }
            if line.hasPrefix("%begin ") {
                // Its last field is 1 when this client sent the command.
                if line.split(separator: " ").last == "1" { answer = [] } else { inOtherAnswer = true }
                return nil
            }
            if line.hasPrefix("%session-changed ") {
                let field = line.split(separator: " ", maxSplits: 2)
                return field.count > 1 ? .attached(String(field[1])) : nil
            }
            if Self.changes.contains(where: line.hasPrefix) { return .changed }
            if line == "%exit" || line.hasPrefix("%exit ") { return .exit }
            if line.hasPrefix("own") { return .own(String(line.dropFirst(4))) }
            return nil
        }
    }
}
