import Foundation

/// What a session's active pane showed when it was captured.
struct ScreenSnapshot: Equatable, Sendable {
    let name: String
    /// The pane's size in cells.
    let columns: Int
    let rows: Int
    /// The printed lines, top to bottom.
    let lines: [[StyledRun]]
}

extension Tmux {
    /// Every session's active pane in one exec, colors included. Each session's capture comes after a
    /// record separator (0x1E, which no screen cell holds) and a header line: the pane's width and
    /// height, then the session's name. Sessions are targeted by ID, so any name is safe.
    static let capture = screens(only: nil)

    /// The active pane of the session named `name` alone, in the same record: the hover picture's.
    static func capture(screenOf name: String) -> String {
        screens(only: name)
    }

    private static func screens(only name: String?) -> String {
        let only = name.map { #"[ "$name" = \#(quote($0)) ] || continue; "# } ?? ""
        return prelude + #"""
        tmux list-sessions -F '#{pane_width} #{pane_height} #{session_id} #{session_name}' 2>/dev/null | \
        while read -r w h id name; do \#(only)printf '\036%s %s %s\n' "$w" "$h" "$name"; tmux capture-pane -p -e -N -t "$id:" 2>/dev/null; done; \
        true
        """#
    }

    /// The screens in `capture` output. Anything before the first separator, such as a login banner,
    /// is not a screen.
    static func parseScreens(_ output: String) -> [ScreenSnapshot] {
        let records = output.unicodeScalars.split(separator: "\u{1E}", omittingEmptySubsequences: false).dropFirst()
        return records.compactMap { record in
            guard let newline = record.firstIndex(of: "\n") else { return nil }
            let header = Substring(record[..<newline]).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard header.count == 3, let columns = Int(header[0]), let rows = Int(header[1]) else { return nil }
            var body = record[record.index(after: newline)...]
            // Every captured line ends in a newline, the last one too.
            if body.last == "\n" { body = body.dropLast() }
            var reader = ScreenReader()
            return ScreenSnapshot(name: String(header[2]), columns: columns, rows: rows, lines: reader.lines(body))
        }
    }
}
