import Foundation

/// A tmux session on a host, as the session list shows it.
struct TmuxSession: Identifiable, Hashable, Sendable {
    let name: String
    let windows: Int
    /// The index of the window the session shows.
    let window: Int
    let lastActivity: Date
    /// What the active pane is running (`TmuxWatch.program(of:status:)`), where, and the model its program
    /// reports (`TmuxWatch.format`).
    let command: String
    let folder: String
    let model: String
    /// What its program is working on, from the host's watcher (`SessionReport.task`): nil until the
    /// watcher reports, and while nothing names a task. Shown in the program's place.
    var task: String? = nil

    var id: String { name }
}

/// One window of a session, as the palette lists it.
struct TmuxWindow: Hashable, Sendable {
    let index: Int
    let name: String
    /// What its active pane runs, as the session list names it.
    let command: String
    /// The window the session shows.
    let isActive: Bool
}

/// The tmux commands Lhûn runs. The only option Lhûn sets is its own sessions' status line, at attach.
enum Tmux {
    /// Non-interactive SSH gets a bare PATH, and Homebrew's tmux lives outside it on the Mac.
    static let prelude = #"export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" LANG="${LANG:-en_US.UTF-8}"; "#

    /// The host's clock and home folder, then one tab-separated line per session. The active pane's
    /// `@lhun-status` names a program behind lhun-pty, as the watcher's reports do.
    static let list = prelude + #"""
    printf '%s\t%s\n' "$(date +%s)" "$HOME"; \
    tmux list-sessions -F $'#{session_name}\t#{session_windows}\t#{window_index}\t#{session_activity}\t#{pane_current_command}\t#{pane_current_path}\t#{@lhun-model}\t#{@lhun-status}' 2>/dev/null; \
    true
    """#

    static func parse(_ output: String) -> [TmuxSession] {
        var lines = output.split(separator: "\n")
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: "\t", omittingEmptySubsequences: false)
        let hostNow = header.first.flatMap { TimeInterval($0) } ?? Date.now.timeIntervalSince1970
        let home = header.count > 1 ? String(header[1]) : ""
        // Activity times come from the host's clock; shift them onto this device's.
        let skew = Date.now.timeIntervalSince1970 - hostNow
        return lines.compactMap { line -> TmuxSession? in
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard field.count == 8 else { return nil }
            let activity = TimeInterval(field[3]) ?? hostNow
            return TmuxSession(
                name: field[0],
                windows: Int(field[1]) ?? 1,
                window: Int(field[2]) ?? 0,
                lastActivity: Date(timeIntervalSince1970: activity + skew),
                command: TmuxWatch.program(of: field[4], status: ProgramStatus(summary: field[7])),
                folder: shortened(field[5], home: home),
                model: field[6]
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func create(_ name: String) -> String {
        prelude + #"tmux new-session -d -s \#(quote(name)) -c "$HOME""#
    }

    /// Starts the session in the folder the other session's active pane is in, or at home when that is
    /// gone.
    static func create(_ name: String, besides session: String) -> String {
        let pane = quote("=" + session + ":")
        return prelude + #"d=$(tmux display -p -t \#(pane) '#{pane_current_path}' 2>/dev/null); tmux new-session -d -s \#(quote(name)) -c "${d:-$HOME}""#
    }

    /// Answers an agent's ask to open a session beside its own (OpenRequest), which it waits on.
    static func clearOpenRequest(of pane: String) -> String {
        prelude + "tmux set-option -p -u -t \(quote(pane)) @lhun-open"
    }

    static func rename(_ name: String, to newName: String) -> String {
        prelude + "tmux rename-session -t \(quote("=" + name)) \(quote(newName))"
    }

    static func kill(_ name: String) -> String {
        prelude + "tmux kill-session -t \(quote("=" + name))"
    }

    /// One tab-separated line per window of the session. The name goes last, since it may hold a tab.
    static func windows(of session: String) -> String {
        prelude + "tmux list-windows -t \(quote("=" + session)) -F $'#{window_index}\\t#{window_active}\\t#{pane_current_command}\\t#{@lhun-status}\\t#{window_name}'"
    }

    static func parseWindows(_ output: String) -> [TmuxWindow] {
        output.split(separator: "\n").compactMap { line in
            let field = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard field.count == 5, let index = Int(field[0]) else { return nil }
            let command = TmuxWatch.program(of: field[2], status: ProgramStatus(summary: field[3]))
            return TmuxWindow(index: index, name: field[4], command: command, isActive: field[1] == "1")
        }
    }

    /// Shows window `index` in the session, and so in every client attached to it.
    static func selectWindow(_ index: Int, in session: String) -> String {
        prelude + "tmux select-window -t \(quote("=\(session):\(index)"))"
    }

    static func selectPane(_ pane: String, window: String, in session: String) -> String {
        prelude + "tmux select-window -t \(quote("=\(session):\(window)")) \\; select-pane -t \(quote(pane))"
    }

    /// Opens a window after the session's last one, in the folder of the pane it shows, and shows it.
    static func newWindow(in session: String) -> String {
        prelude + "tmux new-window -t \(quote("=" + session + ":")) -c '#{pane_current_path}'"
    }

    static func renameWindow(_ index: Int, in session: String, to name: String) -> String {
        prelude + "tmux rename-window -t \(quote("=\(session):\(index)")) \(quote(name))"
    }

    /// Shows the session's next window, or its previous one for a negative step; after the last comes the
    /// first, as in tmux.
    static func stepWindow(_ step: Int, in session: String) -> String {
        prelude + "tmux \(step < 0 ? "previous-window" : "next-window") -t \(quote("=" + session))"
    }

    /// Swaps the window the session shows with its neighbour on the left, for a negative step, or on the
    /// right, and goes on showing it in its new place. At either end nothing moves. swap-window alone
    /// would leave the session showing the neighbour that took the old place.
    static func moveWindow(_ step: Int, in session: String) -> String {
        let neighbour = step < 0 ? #"$1 < c { n = $1 }"# : #"$1 > c && n == "" { n = $1 }"#
        return prelude + #"""
        s=\#(quote("=" + session)); c=$(tmux display -p -t "${s}:" '#{window_index}') && \
        n=$(tmux list-windows -t "$s" -F '#{window_index}' | awk -v c="$c" '\#(neighbour) END { print n }') && \
        if [ -n "$n" ]; then tmux swap-window -s "${s}:$c" -t "${s}:$n" \; select-window -t "${s}:$n"; fi
        """#
    }

    /// Attaches to a session that already exists. It never creates one, so a session killed elsewhere
    /// ends with tmux's own message instead of quietly coming back empty.
    ///
    /// The pid file remembers this device's last client for the session. When a connection dies without
    /// the host noticing, that client lingers attached at the old screen size; hanging it up first keeps
    /// the session sized to the screen that is actually looking at it. Only a pid that tmux itself lists
    /// as a client of this session is touched. The session's status line goes off: Lhûn's pills show
    /// what it showed, and its clock would otherwise redraw an idle screen every minute. With
    /// `ignoringSize` the client carries tmux's `ignore-size` flag, so the screens that already have the
    /// session open keep its size (SharedSize).
    static func attach(_ name: String, client: String, ignoringSize: Bool) -> String {
        let target = quote("=" + name)
        let window = quote("=" + name + ":")
        let flags = ignoringSize ? " -f ignore-size" : ""
        return prelude + #"""
        mkdir -p "$HOME/.cache/lhun"; f=\#(pidFile(name, client: client)); \
        p=$(cat "$f" 2>/dev/null); \
        if [ -n "$p" ] && tmux list-clients -t \#(target) -F '#{client_pid}' 2>/dev/null | grep -qx "$p"; then kill -HUP "$p"; fi; \
        echo $$ > "$f"; tmux set-option -t \#(window) status off 2>/dev/null; exec tmux -u attach-session\#(flags) -t \#(target)
        """#
    }

    /// Where `attach` keeps the pid of this device's last client for the session, as one shell word.
    static func pidFile(_ name: String, client: String) -> String {
        #""$HOME/.cache/lhun/\#(client)-\#(fileSafe(name)).pid""#
    }

    /// The session's active pane, read for the history overlay: its history size and width on one line,
    /// then its lines from `start` to `end` with their colors, each wrapped line joined into one. The
    /// screen's top line is 0 and history counts back from -1; without an end it reads to the bottom of
    /// the screen. tmux stays out of copy mode.
    static func history(_ name: String, from start: Int, to end: Int?) -> String {
        let pane = quote("=" + name + ":")
        let last = end.map(String.init) ?? "-"
        return prelude + #"tmux display -p -t \#(pane) '#{history_size} #{pane_width}' \; capture-pane -p -e -J -S \#(start) -E \#(last) -t \#(pane)"#
    }

    /// The session's screen as text, with lines the terminal wrapped joined back into one.
    static func capture(_ session: String) -> String {
        prelude + "tmux capture-pane -p -J -t \(quote("=" + session + ":"))"
    }

    /// Whether the session's active pane takes a paste as one piece: "1" when its program asked for
    /// bracketed paste, else "0".
    static func takesPastes(_ session: String) -> String {
        prelude + "tmux display -p -t \(quote("=" + session + ":")) '#{bracket_paste_flag}'"
    }

    /// A captured screen without the blanks at the end of each line or the empty lines below the last one.
    static func screenText(_ output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { (line: Substring) -> Substring in
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)].isWhitespace {
                end = line.index(before: end)
            }
            return line[..<end]
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The smallest whole number not already used as a session name, the way tmux names its own.
    static func nextName(after sessions: [TmuxSession]) -> String {
        let taken = Set(sessions.map(\.name))
        var number = 1
        while taken.contains(String(number)) { number += 1 }
        return String(number)
    }

    /// A name for a session opened beside `session`: its name and the next free number, "api-2".
    static func splitName(of session: String, after sessions: [TmuxSession]) -> String {
        let taken = Set(sessions.map(\.name))
        var number = 2
        while taken.contains("\(session)-\(number)") { number += 1 }
        return "\(session)-\(number)"
    }

    /// tmux refuses `.` and `:` in session names, since they separate windows and panes in targets.
    static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/[.:]/, with: "-")
    }

    /// tmux takes a session name only without "." and ":".
    static func isAllowedName(_ name: String) -> Bool {
        !name.contains { $0 == "." || $0 == ":" }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacing("'", with: #"'\''"#) + "'"
    }

    private static func fileSafe(_ name: String) -> String {
        String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }

    static func shortened(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
