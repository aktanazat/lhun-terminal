import CoreGraphics
import Foundation
import Testing
@testable import LhunKit

/// A captured line's text, with its styles dropped.
private func text(_ line: [StyledRun]) -> String {
    line.map(\.text).joined()
}

@Test("Each session's screen follows its separator, and nothing before the first separator is a screen")
func screensSplitOnSeparators() throws {
    // A login banner whose first line reads like a header, before the first separator.
    let output = "9 9 banner\nWelcome\n"
        + "\u{1E}80 24 dev\nfirst line\n\nthird line\n"
        + "\u{1E}120 30 my long session\n$ \n"
        + "\u{1E}80 24 gone\n"
    let screens = Tmux.parseScreens(output)
    try #require(screens.map(\.name) == ["dev", "my long session", "gone"])
    #expect(screens.map(\.columns) == [80, 120, 80])
    #expect(screens.map(\.rows) == [24, 30, 24])
    #expect(screens[0].lines.map(text) == ["first line", "", "third line"])
    #expect(screens[1].lines.map(text) == ["$ "])
    // A session that ended between the list and its capture shows nothing, not a blank line.
    #expect(screens[2].lines.isEmpty)
}

@Test("Every screen starts plain, whatever style the screen before it ended in")
func everyScreenStartsPlain() {
    let output = "\u{1E}20 1 a\n\u{1B}[31mred\n" + "\u{1E}20 1 b\nplain\n"
    #expect(Tmux.parseScreens(output).map(\.lines) == [
        [[StyledRun(text: "red", style: CellStyle(foreground: .indexed(1)))]],
        [[StyledRun(text: "plain", style: CellStyle())]],
    ])
}

@Test("What tmux 3.7 printed for two sessions reads as their screens, tabs and colors kept")
func realCapture() {
    // The capture loop's output for two sessions on tmux 3.7c, byte for byte. tmux writes a tab byte for
    // a tab, which never paints the cells it skips, and ends every line, the last one too, in a newline.
    let output = "\u{1E}40 4 lhun-test-peek-tabs\n"
        + "a\tb\u{1B}[1m\u{1B}[32m$\u{1B}[0m make\tall \n"
        + "\u{1B}[41mred\u{1B}[49m\t\u{1B}[41mbg\u{1B}[49m|         \n"
        + "\tX \n"
        + "\n"
        + "\u{1E}20 2 lhun-test-peek-two words\n"
        + "plain     \n"
        + "\n"
    let plain = CellStyle()
    let red = CellStyle(background: .indexed(1))
    #expect(Tmux.parseScreens(output) == [
        ScreenSnapshot(name: "lhun-test-peek-tabs", columns: 40, rows: 4, lines: [
            [
                StyledRun(text: "a\tb", style: plain),
                StyledRun(text: "$", style: CellStyle(foreground: .indexed(2), bold: true)),
                StyledRun(text: " make\tall ", style: plain),
            ],
            [
                StyledRun(text: "red", style: red),
                StyledRun(text: "\t", style: plain),
                StyledRun(text: "bg", style: red),
                StyledRun(text: "|         ", style: plain),
            ],
            [StyledRun(text: "\tX ", style: plain)],
            [],
        ]),
        ScreenSnapshot(name: "lhun-test-peek-two words", columns: 20, rows: 2, lines: [
            [StyledRun(text: "plain     ", style: plain)],
            [],
        ]),
    ])
}

/// The picture of one captured line on a screen `columns` wide, as raw pixels: blue, green, red and an
/// unused byte each.
private func pixels(of line: String, columns: Int = 24, size: CGSize = CGSize(width: 240, height: 16)) throws -> Data {
    let screen = try #require(Tmux.parseScreens("\u{1E}\(columns) 1 s\n\(line)\n").first)
    let image = try #require(PeekPainter.picture(
        of: screen, palette: LhunTheme.mies(dark: false).palette, font: .xenon, size: size, scale: 2
    ))
    return try #require(image.dataProvider?.data) as Data
}

@Test("A tab in a picture moves on to the next multiple of 8 columns, as the terminal shows it", arguments: [
    ("\tX", "        X"),
    ("ab\tX", "ab      X"),
    ("abcdefgh\tX", "abcdefgh        X"),
    ("a\t\tX", "a               X"),
    // The cells a tab skips take the style tmux gave the tab.
    ("\u{1B}[41;4ma\tb", "\u{1B}[41;4ma       b"),
])
func tabsInPictures(tabbed: String, spaced: String) throws {
    #expect(try pixels(of: tabbed) == pixels(of: spaced))
}

@Test("A block element in a picture keeps the program's color, as the terminal draws it, where text is kept readable")
func blockInPicture() throws {
    // Light Mies's bright black, which the floor darkens on its card.
    let gray = 0x8A
    #expect(Contrast.readable(0x8A8A8A, on: 0xF8F8F7) != 0x8A8A8A)
    let data = try pixels(of: "\u{1B}[90m\u{2588}", columns: 4, size: CGSize(width: 80, height: 40))
    // The block's inside is solid in its color; only its edges blend into the card.
    let solid = stride(from: 0, to: data.count - 3, by: 4).reduce(0) { count, at in
        count + ((0..<3).allSatisfy { abs(Int(data[at + $0]) - gray) <= 1 } ? 1 : 0)
    }
    #expect(solid > 1000)
}

@Test("Escape, Return, the arrows, text and Delete drive the peek; every other key goes on to tmux", arguments: [
    ("\u{1B}", PeekKey.close),
    ("\u{1B}[27u", .close),
    ("\r", .open),
    ("\n", .open),
    ("\u{1B}[13u", .open),
    ("\u{1B}[A", .move(.up)),
    ("\u{1B}OB", .move(.down)),
    ("\u{1B}[C", .move(.right)),
    ("\u{1B}OD", .move(.left)),
    ("q", .type("q")),
    ("é", .type("é")),
    ("\u{7F}", .erase),
    ("\u{08}", .erase),
    ("\t", nil),
    ("ls\r", nil),
    ("\u{1B}b", nil),
    ("\u{1B}[1;5A", nil),
    ("\u{1B}[?62;22c", nil),
] as [(String, PeekKey?)])
func peekKeys(typed: String, expected: PeekKey?) {
    #expect(PeekKey(Array(typed.utf8)) == expected)
}

@Test("Letting go settles on the nearest place, and a flick goes its way", arguments: [
    // Where the finger let go, as a share of the way to where the row rests, and how fast it moved.
    (0.3, 0.0, PeekState.closed),
    (0.7, 0.0, .row),
    (1.0, 0.0, .row),
    (3.0, 0.0, .grid),
    (3.0, -800.0, .closed),
    (0.3, 800.0, .row),
    (1.2, 800.0, .grid),
] as [(Double, Double, PeekState)])
func release(share: Double, velocity: Double, expected: PeekState) {
    let layout = PeekLayout(area: CGSize(width: 1178, height: 760))
    let offset = layout.rowRest * share
    #expect(layout.state(releasedAt: offset, velocity: velocity) == expected)
}
