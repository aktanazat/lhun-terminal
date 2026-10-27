import CryptoKit
import Foundation

/// A command saved in ~/.config/lhun/actions.json on a host, offered in the palette under Actions.
struct SavedAction: Hashable, Sendable {
    /// Where the command runs.
    enum Place: String, Sendable {
        /// Typed at the open session's prompt.
        case here
        /// In a new session, which then opens.
        case session
        /// In a new window of the open session.
        case window
    }

    let title: String
    let command: String
    /// Where to run it; "~/…" starts at the host's home. Without one, a new session starts at home and a
    /// new window in the folder the session is in.
    let folder: String?
    let place: Place

    func actionID(on host: String) -> String {
        let fields = [host, title, command, folder ?? "", place.rawValue]
        let fingerprint = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "action.\(digest)"
    }

    /// The actions in an actions.json file: a JSON list of objects with "title", "command", an optional
    /// "folder", and "where": "here" (the default), "session" or "window". An entry that does not fit is
    /// left out, and so is everything in a file that is not such a list; `problems` says why, for the log.
    static func parse(_ text: String) -> (actions: [SavedAction], problems: [String]) {
        guard !text.allSatisfy(\.isWhitespace) else { return ([], []) }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else {
            return ([], ["the file is not a JSON list"])
        }
        var actions: [SavedAction] = []
        var problems: [String] = []
        for (index, entry) in list.enumerated() {
            do {
                actions.append(try SavedAction(entry: entry))
            } catch {
                problems.append("entry \(index + 1): \(error)")
            }
        }
        return (actions, problems)
    }
}

private extension SavedAction {
    private struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    private init(entry: Any) throws {
        guard let fields = entry as? [String: Any] else { throw Problem(description: "not an object") }
        guard let title = try Self.text(fields, "title") else { throw Problem(description: "no title") }
        guard let command = try Self.text(fields, "command") else { throw Problem(description: "no command") }
        self.title = title
        self.command = command
        folder = try Self.text(fields, "folder")
        if let name = try Self.text(fields, "where") {
            guard let place = Place(rawValue: name) else {
                throw Problem(description: #""where" is "\#(name)", not here, session or window"#)
            }
            self.place = place
        } else {
            place = .here
        }
    }

    /// A text field without its surrounding blanks; nil when it is missing, null or blank.
    private static func text(_ fields: [String: Any], _ name: String) throws -> String? {
        switch fields[name] {
        case nil, is NSNull:
            return nil
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            throw Problem(description: #""\#(name)" is not text"#)
        }
    }
}

extension Tmux {
    /// The host's actions file, or nothing when it has none.
    static let actionsFile = #"cat "$HOME/.config/lhun/actions.json" 2>/dev/null; true"#

    /// Types the action at the session's prompt, after a cd into its folder when it has one, and presses
    /// Return.
    static func run(_ action: SavedAction, in session: String) -> String {
        let pane = quote("=" + session + ":")
        let line = action.folder.map { "cd \(word($0)) && \(action.command)" } ?? action.command
        return prelude + #"tmux send-keys -t \#(pane) -l -- \#(quote(line)) \; send-keys -t \#(pane) Enter"#
    }

    /// Starts session `name` in the action's folder, or at home, with the action typed into it.
    static func start(_ action: SavedAction, as name: String) -> String {
        let pane = quote("=" + name + ":")
        return prelude + #"""
        tmux new-session -d -s \#(quote(name)) -c \#(word(action.folder ?? "~")) \; \
        send-keys -t \#(pane) -l -- \#(quote(action.command)) \; send-keys -t \#(pane) Enter
        """#
    }

    /// Opens a window named after the action in the session, in the action's folder or the session's
    /// own, with the action typed into it.
    static func openWindow(for action: SavedAction, in session: String) -> String {
        let folder = action.folder.map(word) ?? "'#{pane_current_path}'"
        return prelude + #"""
        w=$(tmux new-window -P -F '#{window_id}' -t \#(quote("=" + session + ":")) -n \#(quote(action.title)) -c \#(folder)) && \
        tmux send-keys -t "$w" -l -- \#(quote(action.command)) \; send-keys -t "$w" Enter
        """#
    }

    /// A name for a new session made from `title`: lowercase words joined by dashes, numbered when taken.
    static func sessionName(for title: String, after sessions: [TmuxSession]) -> String {
        let base = clean(title).lowercased().split { $0.isWhitespace || $0 == "-" }.joined(separator: "-")
        guard !base.isEmpty else { return nextName(after: sessions) }
        let taken = Set(sessions.map(\.name))
        var name = base
        var number = 1
        while taken.contains(name) {
            number += 1
            name = "\(base)-\(number)"
        }
        return name
    }
}
