import SwiftTerm
import Testing
@testable import LhunKit

private final class NoHost: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// What a cell shows: its character, colors and styles, with the two names of the default color as one.
private struct Look: Equatable, CustomStringConvertible {
    let character: Character
    let fg: Attribute.Color?
    let bg: Attribute.Color?
    let style: UInt8
    let underline: UnderlineStyle
    let underlineColor: Attribute.Color?

    init(_ cell: CharData, in terminal: Terminal) {
        let shown = terminal.getCharacter(for: cell)
        character = shown == "\0" ? " " : shown
        let plain = { (color: Attribute.Color) -> Attribute.Color? in
            switch color {
            case .defaultColor, .defaultInvertedColor: nil
            case .ansi256, .trueColor: color
            }
        }
        fg = plain(cell.attribute.fg)
        bg = plain(cell.attribute.bg)
        style = cell.attribute.style.rawValue
        underline = cell.attribute.underlineStyle
        underlineColor = cell.attribute.underlineColor.flatMap(plain)
    }

    var description: String { "\(character) fg \(String(describing: fg)) bg \(String(describing: bg)) style \(style) underline \(underline) \(String(describing: underlineColor))" }
}

private func terminal(cols: Int, rows: Int) -> (Terminal, NoHost) {
    let host = NoHost()
    return (Terminal(delegate: host, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0)), host)
}

private func looks(_ terminal: Terminal) -> [[Look]] {
    (0..<terminal.rows).map { row in
        let line = terminal.getLine(row: row)!
        return (0..<terminal.cols).map { Look(line[$0], in: terminal) }
    }
}

@Test("A saved screen fed to a blank terminal of its size shows every cell and the cursor as they were")
func savedScreenDrawsTheSameScreen() throws {
    let (shown, keep) = terminal(cols: 40, rows: 8)
    let screen = [
        "\u{1B}[1;31mbold red\u{1B}[0m \u{1B}[92mbright green\u{1B}[0m \u{1B}[38;5;208m256\u{1B}[0m",
        "\u{1B}[48;2;10;20;30mtrue background   \u{1B}[0m",
        "\u{1B}[3;4:3;58;5;196mcurly italic\u{1B}[0m \u{1B}[7minverse\u{1B}[0m \u{1B}[9;2mstruck dim\u{1B}[0m",
        "wide 漢字 and e\u{301} and \u{1F44D}\u{1F3FD} end",
        "\u{1B}[44m        \u{1B}[0m",
        "",
        "",
        String(repeating: "x", count: 39) + "\u{1B}[35mZ",
    ].joined(separator: "\r\n")
    shown.feed(text: screen + "\u{1B}[0m\u{1B}[4;6H")

    let saved = SavedScreen(of: shown, watched: false)
    let (drawn, keepDrawn) = terminal(cols: saved.cols, rows: saved.rows)
    drawn.feed(byteArray: [UInt8](saved.bytes))

    let before = looks(shown), after = looks(drawn)
    for row in 0..<shown.rows {
        for col in 0..<shown.cols where before[row][col] != after[row][col] {
            Issue.record("row \(row) col \(col): saved \(before[row][col]), drawn \(after[row][col])")
        }
    }
    #expect(drawn.getCursorLocation() == shown.getCursorLocation())
    withExtendedLifetime((keep, keepDrawn)) {}
}

@Test("When tmux leaves the screen after drawing over a saved one, the card goes blank as it would without it")
func savedScreenGoesWhenTmuxLeaves() {
    let (shown, keep) = terminal(cols: 20, rows: 4)
    shown.feed(text: "an old prompt $ ")
    let saved = SavedScreen(of: shown, watched: false)
    let (drawn, keepDrawn) = terminal(cols: saved.cols, rows: saved.rows)
    drawn.feed(byteArray: [UInt8](saved.bytes))

    drawn.feed(text: "\u{1B}[?1049h\u{1B}[H\u{1B}[2J[exited]\u{1B}[?1049l")
    let left = looks(drawn).joined().map(\.character)
    #expect(left.allSatisfy { $0 == " " }, "the saved screen came back: \(String(left))")
    withExtendedLifetime((keep, keepDrawn)) {}
}
