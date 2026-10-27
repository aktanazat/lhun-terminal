import CoreText
import SwiftTerm
import Testing
import UIKit
@testable import LhunKit

private let cell = CGSize(width: 9, height: 18)
private var fonts: Theme.TerminalFonts { Theme.terminalFonts(size: 14) }

/// Mies's dark card.
private func darkStyle() -> HistoryText.Style {
    HistoryText.Style(cell: cell, fonts: fonts, palette: LhunTheme.mies(dark: true).palette)
}

private func hex(_ color: UIColor) -> UInt32 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    func byte(_ c: CGFloat) -> UInt32 { UInt32((c * 255).rounded()) }
    return byte(r) << 16 | byte(g) << 8 | byte(b)
}

@Test("Colors, bold and a reset reach the text as the terminal draws them, kept readable", arguments: [
    ("\u{1B}[31mx", 0xC47A7A, false, nil),
    // Bold brightens the first seven colors.
    ("\u{1B}[1;31mx", 0xD69292, true, nil),
    ("\u{1B}[38;5;208mx", 0xFF8700, false, nil),
    ("\u{1B}[38;2;1;2;3mx", Contrast.readable(0x010203, on: 0x0E0E0E), false, nil),
    ("\u{1B}[41mx", Contrast.readable(0xD6D6D6, on: 0xC47A7A), false, 0xC47A7A),
    ("\u{1B}[7mx", 0x0E0E0E, false, 0xD6D6D6),
    // Faint bright black fades into the card first, and the floor lifts what is left.
    ("\u{1B}[2;90mx", Contrast.readable(0x313131, on: 0x0E0E0E), false, nil),
    ("\u{1B}[1;31;41mo\u{1B}[0mx", 0xD6D6D6, false, nil),
] as [(String, UInt32, Bool, UInt32?)])
func styled(capture: String, text: UInt32, bold: Bool, background: UInt32?) throws {
    var style = darkStyle()
    let drawn = style.text(HistoryText.Rows(Substring(capture), width: 80), endingWith: nil)
    let attributes = drawn.attributes(at: drawn.length - 1, effectiveRange: nil)
    #expect(hex(try #require(attributes[.foregroundColor] as? UIColor)) == text)
    #expect(attributes[.font] as? UIFont == (bold ? fonts.bold : fonts.regular))
    #expect((attributes[.backgroundColor] as? UIColor).map(hex) == background)
}

private final class Replies: TerminalDelegate {
    var text = ""
    func send(source: Terminal, data: ArraySlice<UInt8>) { text += String(decoding: data, as: UTF8.self) }
}

@Test("The live terminal draws colors 16 to 255 in the colors history draws them in")
@MainActor
func liveTerminalMatchesHistoryColors() throws {
    let palette = LhunTheme.mies(dark: true).palette
    func color(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(hex >> 16 & 0xFF) * 257, green: UInt16(hex >> 8 & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
    }
    let replies = Replies()
    let terminal = Terminal(delegate: replies, options: TerminalModel.options)
    terminal.installPalette(colors: palette.ansi.map(color))
    terminal.foregroundColor = color(palette.foreground)
    terminal.backgroundColor = color(palette.background)
    terminal.feed(text: (16..<256).map { "\u{1B}]4;\($0);?\u{07}" }.joined())

    let reply = #/4;(\d+);rgb:([0-9a-f]{4})/([0-9a-f]{4})/([0-9a-f]{4})/#
    var live: [Int: UInt32] = [:]
    for match in replies.text.matches(of: reply) {
        let channels = try [match.2, match.3, match.4].map { try #require(UInt32($0, radix: 16)) >> 8 }
        live[try #require(Int(match.1))] = channels[0] << 16 | channels[1] << 8 | channels[2]
    }
    let history = Dictionary(uniqueKeysWithValues: (16..<256).map { ($0, palette.hex(.indexed(UInt8($0)), default: 0)) })
    #expect(live == history)
}

@Test("Letters and box drawing are kept readable; block elements and Powerline separators keep the program's color")
func shapesKeepTheirColor() throws {
    var style = darkStyle()
    // Dark Mies's bright black on its own card, which the floor lightens.
    let floored = Contrast.readable(0x545454, on: 0x0E0E0E)
    #expect(floored != 0x545454)
    let drawn = style.text(HistoryText.Rows("\u{1B}[90mab\u{E0B0}\u{2588}\u{2500}", width: 80), endingWith: nil)
    let colors = try (0..<5).map { index in
        hex(try #require(drawn.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor))
    }
    #expect(colors == [floored, floored, 0x545454, 0x545454, floored])
}

@Test("Each character covers its own cells, and each row is one cell tall with the terminal's baseline")
func cellsAndRows() {
    var style = darkStyle()
    let layout = HistoryText.Layout(cell: cell, font: fonts.regular)
    layout.container.size = CGSize(width: 10 * cell.width, height: .greatestFiniteMagnitude)
    // Three rows, the last empty, as the bottom of a screen often is.
    layout.storage.setAttributedString(style.text(HistoryText.Rows("a漢b\n\u{1F600}x\n\n", width: 10), endingWith: nil))
    layout.manager.ensureLayout(for: layout.container)
    let baseline = cell.height - ceil(CTFontGetDescent(fonts.regular) + CTFontGetLeading(fonts.regular))
    // (UTF-16 offset, row, column): a wide character takes two columns, the emoji too.
    for (offset, row, column) in [(0, 0, 0), (1, 0, 1), (2, 0, 3), (4, 1, 0), (6, 1, 2)] {
        let glyph = layout.manager.glyphIndexForCharacter(at: offset)
        let fragment = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layout.manager.location(forGlyphAt: glyph)
        #expect(fragment.minY == CGFloat(row) * cell.height, "row of \(offset)")
        #expect(abs(location.x - CGFloat(column) * cell.width) < 0.01, "column of \(offset): \(location.x)")
        #expect(abs(location.y - baseline) < 0.01, "baseline of \(offset): \(location.y)")
    }
    #expect(layout.manager.usedRect(for: layout.container).height == 3 * cell.height)
}

@Test("Lines are cut into rows where tmux wrapped them", arguments: [
    ("0123456789abc", 10, ["0123456789", "abc"], [true, false]),
    // A wide character that would cross the edge starts the next row.
    ("abcdefghi漢x", 10, ["abcdefghi", "漢x"], [true, false]),
    ("a\n\nb", 10, ["a", "", "b"], [false, false, false]),
    // A tab reaches the next stop, or the last column when no stop is left, and is ignored there.
    ("a\tb", 20, ["a       b"], [false]),
    ("a\tb\tc", 12, ["a       b  c"], [false]),
    ("abcdefgh\tX", 10, ["abcdefgh X"], [false]),
    ("abcdefghi\tX", 10, ["abcdefghiX"], [false]),
    ("abcdefghij\tX", 10, ["abcdefghij", "X"], [true, false]),
] as [(String, Int, [String], [Bool])])
func rows(capture: String, width: Int, texts: [String], wraps: [Bool]) {
    let rows = HistoryText.Rows(Substring(capture + "\n"), width: width)
    #expect(rows.rows.map(HistoryText.Rows.text(of:)) == texts)
    #expect(rows.wraps == wraps)
}

@Test("An older stretch joins the newer one where tmux had them, and a copy of both gives back the lines", arguments: [
    // The newer stretch starts inside a wrapped line: the older one ends with the row it starts with.
    ("first\n0123456789abcdefghij\n", "abcdefghij0123\nlast\n"),
    // The newer stretch starts with a line of its own.
    ("first\n0123456789abcdefghij0123\nlast\n", "last\n"),
])
func stitching(older: String, newer: String) {
    var style = darkStyle()
    var olderRows = HistoryText.Rows(Substring(older), width: 10)
    let newerRows = HistoryText.Rows(Substring(newer), width: 10)
    let goesOn = olderRows.dropLast(matching: HistoryText.Rows.text(of: newerRows.rows[0]))
    let text = NSMutableAttributedString(attributedString: style.text(olderRows, endingWith: goesOn ? HistoryText.wrap : HistoryText.lineEnd))
    text.append(style.text(newerRows, endingWith: nil))
    #expect(HistoryText.copied(Substring(text.string)) == "first\n0123456789abcdefghij0123\nlast")
}

@Test("An older stretch that does not end with the newer one's first row keeps all its rows")
func stitchingMismatch() {
    var rows = HistoryText.Rows("first\nsecond\n", width: 10)
    let goesOn = rows.dropLast(matching: "other")
    #expect(!goesOn)
    #expect(rows.rows.count == 2)
}

/// Takes nothing back from the terminal; the test only feeds it.
private final class Quiet: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@Test("The screen reads into rows as a capture does: styles kept, a wide character once, a wrapped row marked, blanks at a line's end left off unless colored")
func screenRows() {
    let quiet = Quiet()
    let terminal = Terminal(delegate: quiet, options: TerminalOptions(cols: 10, rows: 4))
    terminal.feed(text: "a\u{1B}[31mb\u{1B}[0m \u{1B}[41m \u{1B}[0m  \r\n0123456789wrap\r\n\u{1B}[1;3;7m漢\u{1B}[0mx")
    let rows = HistoryText.Rows(screen: terminal)
    let plain = CellStyle()
    var red = plain
    red.foreground = .indexed(1)
    var redBehind = plain
    redBehind.background = .indexed(1)
    var loud = plain
    loud.bold = true
    loud.italic = true
    loud.inverse = true
    #expect(rows.rows == [
        [StyledRun(text: "a", style: plain), StyledRun(text: "b", style: red), StyledRun(text: " ", style: plain), StyledRun(text: " ", style: redBehind)],
        [StyledRun(text: "0123456789", style: plain)],
        [StyledRun(text: "wrap", style: plain)],
        [StyledRun(text: "漢", style: loud), StyledRun(text: "x", style: plain)],
    ])
    #expect(rows.wraps == [false, true, false, false])
}

@Test("A copy joins wrapped rows back into their lines and leaves off the blanks after each", arguments: [
    ("ab  \u{2028}cd  \nef  ", "ab  cd\nef"),
    ("x \u{2028}", "x"),
    ("\n\n", "\n\n"),
])
func copied(selection: String, expected: String) {
    #expect(HistoryText.copied(Substring(selection)) == expected)
}

@MainActor
@Test("The terminal's own replies to tmux leave history open; keys close it", arguments: [
    ("\u{1B}]11;rgb:0e0e/0e0e/0e0e\u{1B}\\", true),
    ("\u{1B}P>|SwiftTerm\u{1B}\\", true),
    ("\u{1B}[?62;22c", true),
    ("\u{1B}[>0;276;0c", true),
    ("\u{1B}[I", true),
    ("\u{1B}[O", true),
    ("a", false),
    ("\r", false),
    ("\u{1B}", false),
    ("\u{1B}[A", false),
    ("\u{1B}[1;5A", false),
    ("\u{1B}[200~paste", false),
    ("\u{1B}OP", false),
])
func replies(bytes: String, isReply: Bool) {
    #expect(HistoryView.isReply(ArraySlice(bytes.utf8)) == isReply)
}

@Test("Prompt navigation follows tmux's row markers, not text that resembles a prompt")
func promptMarkers() throws {
    let capture = """
    982 87
    -982 P user@host %
    -977 WP $
    -976 W prompt-looking text
    -20 P user@host %

    """
    let prompts = try #require(HistoryText.Prompts(capture))
    #expect(prompts.history == 982)
    #expect(prompts.width == 87)
    #expect(prompts.rows == [-982, -977, -20])
    #expect(HistoryText.Prompts("982 87\n-20 W $")?.rows == [])
    #expect(HistoryText.Prompts("tmux: unknown flag\n") == nil)
}
