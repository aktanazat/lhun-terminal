import Foundation

/// Watching every tmux session on a host at once, so a session pill can show what its pane runs and
/// whether it is working, finished, or waiting on him, without opening the session.
///
/// One control-mode client per host attaches to a single session and subscribes to a format that loops
/// over every pane of every session (`refresh-client -B`). tmux checks subscriptions once a second and
/// sends one only when its value changed, so a quiet host sends nothing and Lhûn runs no timer. The
/// format leaves out activity times and screen contents on purpose: they change all the time.
enum TmuxWatch {
    static let subscription = "lhun"

    /// The spinner frames agents put at the front of their pane title: omp's ten, and the two more that
    /// Claude Code cycles through. tmux folds every frame into `spinner` before it compares values, so an
    /// animating title does not send a subscription every second. The frames are listed one by one
    /// because tmux 3.4 on Linux does not match character ranges outside ASCII.
    static let spinnerFrames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠂⠐"
    static let spinner: Character = "⠿"

    /// The watcher's exit status when the host has no session to attach to.
    static let noSessions = 3

    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    static let format: String = {
        let shown = "#{&&:#{window_active},#{pane_active}}"
        let frames = spinnerFrames.map(String.init).joined(separator: "|")
        let fields = [
            "#{session_name}", "#{window_id}", "#{window_index}", "#{window_bell_flag}", shown, "#{pane_current_command}",
            "#{pane_current_path}", "#{alternate_on}", "#{pane_pb_state}",
            "#{=64;s/\(frames)/\(spinner)/:pane_title}", "#{@lhun-model}", "#{@lhun-status}", "#{@lhun-open}", "#{pane_id}",
        ]
        return "#{S:#{W:#{P:" + fields.joined(separator: unit) + record + "}}}"
    }()

    /// Prints the home folder and the host's name, then attaches to one session and subscribes. It
    /// prefers a session someone already has open, since an attached session's shown window never keeps
    /// a bell flag; then one whose shown window has no bell waiting, since attaching counts as seeing it;
    /// then the oldest. The client takes no pane output and leaves the session's size alone. The only
    /// thing ever written to it is `look`, which its pseudo-terminal does not echo back into the output.
    static let command = Tmux.prelude + #"""
    stty -echo 2>/dev/null; s=$(tmux list-sessions -F '#{?session_attached,0,1}#{window_bell_flag} #{session_activity} #{session_name}' 2>/dev/null | LC_ALL=C sort | head -n 1 | cut -d' ' -f3-); \
    [ -n "$s" ] || exit \#(noSessions); printf 'home %s\nhostname %s\n' "$HOME" "$(uname -n)"; \
    exec tmux -u -C attach-session -t "=$s" -f no-output,ignore-size \; refresh-client -B '\#(subscription)::\#(format)'
    """#

    /// Written to the watcher when he leaves a session. tmux answers at once with every pane in the
    /// subscription's format, as it stands when tmux reads the line, while a subscription waits for the
    /// check tmux makes once a second: the answer is the session as he left it.
    static let look = Array("display-message -p '\(format)'\n".utf8)

    enum Event: Equatable, Sendable {
        /// The host's home folder, printed before tmux starts.
        case home(String)
        /// The host's name, printed before tmux starts: tmux titles a pane with it until a program in
        /// the pane titles it.
        case hostname(String)
        /// Every pane on the host, after something about one of them changed or in answer to a look.
        /// `seen` names the sessions he left after tmux took it: what it shows of them was on his screen.
        case panes([PaneReport], seen: Set<String>)
        /// A session started, ended or was renamed.
        case sessionsChanged
        /// A client came to the session with this name: attached to it, or switched to it.
        case clientJoined(String)
        /// tmux let the client go.
        case exit
    }

    /// Splits the watcher's output into events. It arrives through a pseudo-terminal in arbitrary chunks,
    /// so lines end in "\r\n" and a chunk can stop in the middle of a line or of a character.
    struct Stream {
        private enum Reply {
            /// To one of the commands the watcher started with, which print nothing worth reading.
            case startup
            /// To a look, as much of it as has come.
            case look([UInt8])
        }

        private var pending: [UInt8] = []
        /// Inside a command's reply, between `%begin` and `%end` or `%error`.
        private var reply: Reply?
        /// Sessions he left whose look tmux has not answered yet, oldest first. tmux answers commands in
        /// order, after every report it took before reading them.
        private var looks: [String] = []

        private static let begin = Array("%begin ".utf8)
        private static let end = Array("%end ".utf8)
        private static let error = Array("%error ".utf8)
        private static let changed = Array("%subscription-changed ".utf8)
        private static let sessionsChanged = Array("%sessions-changed".utf8)
        private static let exit = Array("%exit".utf8)
        private static let exitWithReason = Array("%exit ".utf8)
        private static let clientSessionChanged = Array("%client-session-changed ".utf8)
        private static let home = Array("home ".utf8)
        private static let hostname = Array("hostname ".utf8)
        private static let name = Array(TmuxWatch.subscription.utf8)
        private static let valueStart = Array(" : ".utf8)

        /// He left `session`: the watcher writes the line this returns to tmux, and until tmux answers
        /// it, every report names the session as seen.
        mutating func look(leaving session: String) -> [UInt8] {
            looks.append(session)
            return TmuxWatch.look
        }

        mutating func feed(_ bytes: [UInt8]) -> [Event] {
            pending += bytes
            var events: [Event] = []
            var start = 0
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                var line = pending[start..<newline]
                if line.last == 0x0D { line.removeLast() }
                if let event = event(for: line) { events.append(event) }
                start = newline + 1
            }
            pending.removeFirst(start)
            return events
        }

        private mutating func event(for line: ArraySlice<UInt8>) -> Event? {
            if let reply {
                let ended = line.starts(with: Self.end)
                guard ended || line.starts(with: Self.error) else {
                    if case .look(let body) = reply { self.reply = .look(body + (body.isEmpty ? [] : [0x0A]) + line) }
                    return nil
                }
                self.reply = nil
                guard case .look(let body) = reply else { return nil }
                let seen = Set(looks)
                if !looks.isEmpty { looks.removeFirst() }
                return ended ? .panes(PaneReport.parse(Self.unescaped(body)[...]), seen: seen) : nil
            }
            if line.starts(with: Self.begin) {
                // `%begin <time> <number> <flags>`: flags is 1 for a command the client wrote itself,
                // and the only one Lhûn writes is a look.
                reply = line.split(separator: 0x20).last?.elementsEqual([0x31]) == true ? .look([]) : .startup
                return nil
            }
            if line.starts(with: Self.changed) { return subscription(line.dropFirst(Self.changed.count)) }
            if line.elementsEqual(Self.sessionsChanged) { return .sessionsChanged }
            if line.starts(with: Self.clientSessionChanged) {
                return joined(line.dropFirst(Self.clientSessionChanged.count))
            }
            if line.elementsEqual(Self.exit) || line.starts(with: Self.exitWithReason) { return .exit }
            if line.starts(with: Self.home) {
                return .home(String(decoding: line.dropFirst(Self.home.count), as: UTF8.self))
            }
            if line.starts(with: Self.hostname) {
                return .hostname(String(decoding: line.dropFirst(Self.hostname.count), as: UTF8.self))
            }
            return nil
        }

        /// `<name> $<session> @<window> <window index> %<pane> : <value>`, with `-` for the unused ids.
        private func subscription(_ rest: ArraySlice<UInt8>) -> Event? {
            guard let space = rest.firstIndex(of: 0x20), rest[..<space].elementsEqual(Self.name),
                  let value = rest.firstRange(of: Self.valueStart) else { return nil }
            return .panes(PaneReport.parse(rest[value.upperBound...]), seen: Set(looks))
        }

        /// tmux 3.4 writes the control characters in a reply as vis(3) does, the unit separator as
        /// `\037`; tmux 3.7 writes them as they are.
        private static func unescaped(_ bytes: [UInt8]) -> [UInt8] {
            guard bytes.contains(0x5C) else { return bytes }
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var index = 0
            while index < bytes.count {
                if bytes[index] == 0x5C, index + 3 < bytes.count,
                   let byte = octal(bytes[index + 1], bytes[index + 2], bytes[index + 3]) {
                    out.append(byte)
                    index += 4
                } else {
                    out.append(bytes[index])
                    index += 1
                }
            }
            return out
        }

        private static func octal(_ high: UInt8, _ middle: UInt8, _ low: UInt8) -> UInt8? {
            guard (0x30...0x33).contains(high), (0x30...0x37).contains(middle), (0x30...0x37).contains(low) else {
                return nil
            }
            return (high - 0x30) << 6 | (middle - 0x30) << 3 | (low - 0x30)
        }

        /// `<client> $<session> <session name>`.
        private func joined(_ rest: ArraySlice<UInt8>) -> Event? {
            guard let client = rest.firstIndex(of: 0x20),
                  let id = rest[(client + 1)...].firstIndex(of: 0x20) else { return nil }
            return .clientJoined(String(decoding: rest[(id + 1)...], as: UTF8.self))
        }
    }

    /// Programs that wait for him when nothing runs in front of them. Remote shells count too: an SSH
    /// session to another machine is a place, not a task.
    private static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh",
        "login", "su", "ssh", "mosh", "mosh-client", "et", "tmux",
    ]

    /// tmux names a pane for the program in front of it, and lhun-pty (tools/status) runs Claude Code on a
    /// terminal of its own, so a pane running Claude Code through it is named for lhun-pty.
    static let relay = "lhun-pty"

    /// What a pane runs: tmux's name for it or, behind lhun-pty, the program's own once it has reported.
    static func program(of command: String, status: ProgramStatus?) -> String {
        command == relay ? status?.app ?? command : command
    }

    /// Agents idle at their own prompt for hours, so running is no sign of work; only their titles are.
    private static let agents: Set<String> = [
        "omp", "pi", "claude", "codex", "gemini", "opencode", "amp", "aider", "cursor-agent", "goose", "crush",
        "kimi", "qwen", "droid", "akyl", "herdr", relay,
    ]

    static func isShell(_ command: String) -> Bool {
        shells.contains(program(command))
    }

    static func isAgent(_ command: String) -> Bool {
        let name = program(command)
        // Claude Code retitles its process to its version; Codex runs as "codex-aarch64-apple-darwin".
        if name.wholeMatch(of: /\d+(\.\d+)+/) != nil { return true }
        return agents.contains(agentName(name))
    }

    /// What an agent's title says it is working on, or nil while it says no more than which agent runs
    /// where. Claude Code titles itself "✳ Fix login redirect", a spinner frame in place of the ✳ while
    /// it works, and "✳ Claude Code" until it has a task; omp "π > Fix login redirect", the > a spinner
    /// or ! by its state, and its folder's name until the session has one. An agent that sets no title
    /// keeps the shell's, such as "app: codex" or "~/src/app", or tmux's own: the host's name.
    static func task(title: String, agent: String, folder: String, hostname: String) -> String? {
        var words = ProgramStatus.disarmed(title).split(whereSeparator: \.isWhitespace)
        if words.first == "π" || words.first == "π:" { words.removeFirst() }
        // Past the glyph for its state.
        let said = words.drop { bare($0).isEmpty }
        let host = hostname.lowercased()
        let places = [host, String(host.prefix { $0 != "." }), folder.split(separator: "/").last?.lowercased() ?? ""]
        // Where it runs: the host or someone at it, a folder, a path or a shell, and what separates them.
        let rest = said.drop { word in
            let core = bare(word).lowercased()
            if core.isEmpty || core.first == "/" || core.first == "~" { return true }
            return places.contains(core.split(separator: "@").last.map(String.init) ?? core) || isShell(core)
        }
        // Then, at most, the agent's own name or a command line that starts with it.
        let name = program(agent)
        guard let next = rest.first.map({ bare($0).lowercased() }), next != name, next != agentName(name) else {
            return nil
        }
        return said.joined(separator: " ")
    }

    /// The name an agent goes by: "codex" for codex-aarch64-apple-darwin, "claude" for claude-code.
    private static func agentName(_ name: String) -> String {
        guard !agents.contains(name), let first = name.split(separator: "-").first.map(String.init),
              agents.contains(first) else { return name }
        return first
    }

    /// A title's word without the marks around it, but with the / or ~ that starts a path: "(host)" is
    /// "host", "app:" is "app" and "✳" is nothing.
    private static func bare(_ word: Substring) -> Substring {
        let kept: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "~" }
        guard let first = word.firstIndex(where: kept), let last = word.lastIndex(where: kept) else { return "" }
        return word[first...last]
    }

    /// "-zsh", "/bin/zsh" and "Zsh" are all "zsh".
    private static func program(_ command: String) -> String {
        var name = command.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return String(name.drop { $0 == "-" })
    }
}

/// One pane, as the watcher's subscription reports it.
struct PaneReport: Equatable, Sendable {
    /// The pane's progress bar, from OSC 9;4 (tmux 3.6 and later).
    enum Progress: Equatable, Sendable {
        case none
        case running
        case paused
        case failed

        init(_ state: String) {
            switch state {
            case "normal", "indeterminate": self = .running
            case "paused": self = .paused
            case "error": self = .failed
            default: self = .none
            }
        }
    }

    let session: String
    let window: String
    /// Where the window sits in its session's list, which the session pill shows.
    let windowIndex: Int
    /// The window rang a bell, and nobody has looked at it since.
    let windowBell: Bool
    /// The pane the session shows: its active window's active pane.
    let isShown: Bool
    let command: String
    let path: String
    let alternateScreen: Bool
    let progress: Progress
    /// Its title, up to 64 cells, spinner frames folded into `TmuxWatch.spinner`.
    let title: String
    let model: String
    /// What a program in it reports of itself, once one has.
    var status: ProgramStatus? = nil
    /// A session an agent in it asked to have beside it, until Lhûn or the agent clears the ask.
    var openRequest: OpenRequest? = nil
    let pane: String

    /// What the pane runs, by `TmuxWatch.program(of:status:)`.
    var program: String {
        TmuxWatch.program(of: command, status: status)
    }

    /// What its program is working on: the title it reports of itself (OSC 7501), else an agent's own
    /// title as `TmuxWatch.task` reads it. Another program's title names a file or a place, and a title
    /// outlives the program that set it, so only an agent's counts.
    func task(hostname: String) -> String? {
        if let title = status?.title { return title }
        guard TmuxWatch.isAgent(command) else { return nil }
        return TmuxWatch.task(title: title, agent: program, folder: path, hostname: hostname)
    }

    static func parse(_ value: ArraySlice<UInt8>) -> [PaneReport] {
        value.split(separator: 0x1E).compactMap { record in
            let field = record.split(separator: 0x1F, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard field.count == 14, let windowIndex = Int(field[2]),
                  field[13].first == "%", field[13].count > 1,
                  field[13].dropFirst().utf8.allSatisfy({ (48...57).contains($0) })
            else { return nil }
            return PaneReport(
                session: field[0],
                window: field[1],
                windowIndex: windowIndex,
                windowBell: field[3] == "1",
                isShown: field[4] == "1",
                command: field[5],
                path: field[6],
                alternateScreen: field[7] == "1",
                progress: Progress(field[8]),
                title: field[9],
                model: field[10],
                status: ProgramStatus(summary: field[11]),
                openRequest: OpenRequest(field[12]),
                pane: field[13]
            )
        }
    }

    enum Activity: Equatable, Sendable {
        case quiet
        /// Something runs in front of the shell, an agent's title spins, or a progress bar is up.
        case working
        /// An agent waits at its prompt, so a bell from it means it finished.
        case ready
        /// An agent asked something or wants approval, or a progress bar shows an error.
        case needsYou
    }

    /// What the pane's programs say of themselves, else, on screen, whether a program runs in front of
    /// the shell.
    var activity: Activity {
        if let own = ownActivity { return own }
        // Only the pane on screen counts by its program: a background pane's command is not news.
        if isShown, !alternateScreen, !TmuxWatch.isShell(command), !TmuxWatch.isAgent(command) { return .working }
        return .quiet
    }

    /// What the pane's programs say of themselves, or nil when they say nothing. A program's own report
    /// wins over every guess. Once one has reported, the pane's progress bar no longer counts, as the
    /// protocol asks, until the terminal resets; its title still does once no record is left.
    var ownActivity: Activity? {
        if let state = status?.state {
            switch state {
            case .working: return .working
            case .blocked: return .needsYou
            case .done, .error, .idle: return .ready
            }
        }
        let progress = status == nil ? progress : .none
        if progress == .failed { return .needsYou }
        if let guessed = agentActivity(progress: progress) { return guessed }
        return progress == .none ? nil : .working
    }

    /// What an agent's title says, for the agents whose titles say anything. omp titles itself "π" and a
    /// state: a spinner while working, ">" at its prompt, "!" when it asks or wants approval. pi titles
    /// itself "π - " and the session, with no state, so only its progress bar tells whether it works:
    /// it runs as node, which the rule for programs in front of the shell would count as work. Claude
    /// Code shows a spinner frame while working and "✳" at its prompt.
    private func agentActivity(progress: Progress) -> Activity? {
        let cells = Array(title)
        if cells.count >= 3, cells[0] == "π", cells[1] == " " {
            switch cells[2] {
            case TmuxWatch.spinner: return .working
            case ">": return .ready
            case "!": return .needsYou
            default: return progress == .none ? .quiet : .working
            }
        }
        guard cells.count >= 2, cells[1] == " " else { return nil }
        switch cells[0] {
        case TmuxWatch.spinner: return .working
        case "✳": return .ready
        default: return nil
        }
    }
}

/// An agent's ask to show another session beside its own: `right %<pane> <session>` or `below %<pane>
/// <session>`, set on its pane by `lhun open` (tools/agents). Lhûn clears it once the session is open, which
/// is how the agent hears that he sees it.
struct OpenRequest: Hashable, Sendable {
    /// The asking pane, as tmux names it in `TMUX_PANE`.
    let pane: String
    let session: String
    let below: Bool

    init?(_ value: String) {
        let parts = value.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0] == "right" || parts[0] == "below",
              parts[1].count > 1, parts[1].first == "%", parts[1].dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        pane = String(parts[1])
        session = String(parts[2])
        below = parts[0] == "below"
    }
}

/// One session, from its panes.
struct SessionReport: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case quiet
        case working
        case needsYou
    }

    /// A program's report from one of the session's panes.
    struct PaneStatus: Equatable, Sendable {
        let window: String
        let status: ProgramStatus

        /// A done or an error, named so that he can have seen it: its window and the report's sequence.
        var finish: String? {
            guard status.state == .done || status.state == .error, let seq = status.seq else { return nil }
            return "\(window) \(seq)"
        }
    }

    let name: String
    let panes: [PaneReport]
    let windows: Int
    /// What the shown pane runs, where, and the model its program reports.
    let command: String
    let folder: String
    let model: String
    /// What the shown pane's program is working on (`PaneReport.task`), or nil while nothing says.
    let task: String?
    /// The window the session shows, and its index.
    let shownWindow: String
    let shownIndex: Int
    /// The shown pane is on the alternate screen: a full-screen program has it.
    let alternateScreen: Bool
    /// Windows that rang a bell nobody has looked at yet.
    let bells: Set<String>
    /// Windows with an agent waiting at its prompt: a bell from one of them means it finished.
    let readyWindows: Set<String>
    /// The most urgent of its panes.
    let activity: Activity
    /// What programs in its panes report of themselves, the most urgent first, then in pane order.
    let statuses: [PaneStatus]
    /// Sessions agents in its panes asked to have beside it, in pane order.
    let openRequests: [OpenRequest]
    /// A program in it says what it is doing: it reports anything but idle (OSC 7501), or, reporting
    /// nothing, its progress bar is up or an agent's title says it works or asks. That a program runs in
    /// front of the shell says nothing of what it does.
    let reportsActivity: Bool

    /// Its programs' finishes, as `PaneStatus.finish` names them.
    var finishes: Set<String> {
        Set(statuses.compactMap(\.finish))
    }

    /// Groups pane reports by session, in the order tmux listed them. `hostname` is the host's own name,
    /// which tmux titles a pane with until a program titles it; empty while unknown.
    static func sessions(from panes: [PaneReport], home: String, hostname: String = "") -> [SessionReport] {
        var groups: [(name: String, panes: [PaneReport])] = []
        var index: [String: Int] = [:]
        for pane in panes {
            if let position = index[pane.session] {
                groups[position].panes.append(pane)
            } else {
                index[pane.session] = groups.count
                groups.append((pane.session, [pane]))
            }
        }
        return groups.map { SessionReport(name: $0.name, panes: $0.panes, home: home, hostname: hostname) }
    }

    /// `panes` is never empty: a session always has a pane.
    private init(name: String, panes: [PaneReport], home: String, hostname: String) {
        let shown = panes.first(where: \.isShown) ?? panes[0]
        let activities = panes.map(\.activity)
        self.name = name
        self.panes = panes
        windows = Set(panes.map(\.window)).count
        command = shown.program
        folder = Tmux.shortened(shown.path, home: home)
        model = shown.model
        task = shown.task(hostname: hostname)
        shownWindow = shown.window
        shownIndex = shown.windowIndex
        alternateScreen = shown.alternateScreen
        bells = Set(panes.filter(\.windowBell).map(\.window))
        readyWindows = Set(zip(panes, activities).filter { $0.1 == .ready }.map { $0.0.window })
        activity = activities.contains(.needsYou) ? .needsYou : activities.contains(.working) ? .working : .quiet
        let reported = panes.enumerated().compactMap { index, pane -> (Int, ProgramStatus.State, PaneStatus)? in
            guard let status = pane.status, let state = status.state else { return nil }
            return (index, state, PaneStatus(window: pane.window, status: status))
        }
        statuses = reported.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }.map(\.2)
        openRequests = panes.compactMap(\.openRequest)
        reportsActivity = statuses.contains { $0.status.state != .idle }
            || panes.contains { $0.ownActivity == .working || $0.ownActivity == .needsYou }
    }
}
