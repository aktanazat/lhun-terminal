import Testing
@testable import LhunKit

/// The lines of one capture, read by one reader.
private func read(_ capture: String) -> [[StyledRun]] {
    var reader = ScreenReader()
    return reader.lines(Substring(capture).unicodeScalars)
}

/// A captured line's text, with its styles dropped.
private func text(_ line: [StyledRun]) -> String {
    line.map(\.text).joined()
}

/// The style of "x" after `CSI <parameters> m`, as the only cell of a capture.
private func style(after parameters: String) throws -> CellStyle {
    let run = try #require(read("\u{1B}[\(parameters)mx").first?.first)
    #expect(run.text == "x")
    return run.style
}

@Test("A style carries from line to line within one capture")
func styleCarriesAcrossLines() {
    let red = CellStyle(foreground: .indexed(1))
    #expect(read("\u{1B}[31mred\nstill red\u{1B}[0m plain") == [
        [StyledRun(text: "red", style: red)],
        [StyledRun(text: "still red", style: red), StyledRun(text: " plain", style: CellStyle())],
    ])
}

@Test("SGR parameters give the style tmux meant", arguments: [
    ("31", CellStyle(foreground: .indexed(1))),
    ("97", CellStyle(foreground: .indexed(15))),
    ("100", CellStyle(background: .indexed(8))),
    ("38;5;208", CellStyle(foreground: .indexed(208))),
    ("38;2;10;20;30", CellStyle(foreground: .rgb(10, 20, 30))),
    ("48;5;17", CellStyle(background: .indexed(17))),
    // The colon forms, with and without a color space before r.
    ("38:5:208", CellStyle(foreground: .indexed(208))),
    ("38:2::10:20:30", CellStyle(foreground: .rgb(10, 20, 30))),
    ("38:2:10:20:30", CellStyle(foreground: .rgb(10, 20, 30))),
    // A color's arguments are not attributes of their own.
    ("38;5;208;1", CellStyle(foreground: .indexed(208), bold: true)),
    ("48;2;1;2;3;7", CellStyle(background: .rgb(1, 2, 3), inverse: true)),
    ("58;5;1;4", CellStyle(underline: true)),
    // 4:3 is a curly underline, not an underline and an italic.
    ("4:3", CellStyle(underline: true)),
    ("4;4:0", CellStyle()),
    ("2;3;7;8;9", CellStyle(faint: true, italic: true, inverse: true, hidden: true, strikethrough: true)),
    ("1;2;22", CellStyle()),
    ("1;31;0", CellStyle()),
    // An empty parameter is a 0.
    ("1;", CellStyle()),
    ("31;39;41;49", CellStyle()),
])
func sgr(parameters: String, expected: CellStyle) throws {
    #expect(try style(after: parameters) == expected)
}

@Test("Escape sequences other than SGR, and control characters other than a tab, never show up as text")
func otherSequencesAreSkipped() {
    let line = "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\ "
        + "\u{1B}]8;;https://example.com\u{07}bel\u{1B}]8;;\u{07}"
        + "\u{1B}[?25h\u{1B}[>4;1m\u{1B}(B\u{07}end"
    #expect(read(line) == [[StyledRun(text: "link belend", style: CellStyle())]])
}

@Test("A cut-off escape sequence never swallows the line break after it")
func cutOffSequenceKeepsTheLineBreak() {
    #expect(read("abc\u{1B}[3\nnext").map(text) == ["abc", "next"])
}

@Test("Cells in the line-drawing set read as box-drawing characters")
func lineDrawing() {
    #expect(read("\u{0E}lqk\u{0F}x").map(text) == ["┌─┐x"])
}

@Test("A tab stays in the text, in the style around it")
func tabsStay() {
    #expect(read("a\tb\u{1B}[1m\tc") == [[
        StyledRun(text: "a\tb", style: CellStyle()),
        StyledRun(text: "\tc", style: CellStyle(bold: true)),
    ]])
}

@Test("A tab moves on to the next multiple of 8, and any other character past the cells it takes", arguments: [
    ("\t", 0, 8),
    ("\t", 5, 8),
    ("\t", 7, 8),
    ("\t", 8, 16),
    ("a", 7, 8),
    ("界", 3, 5),
    // An emoji, which shows as a picture.
    ("\u{1F642}", 3, 5),
    // A combining acute accent sits on the character before it.
    ("\u{301}", 3, 3),
] as [(Unicode.Scalar, Int, Int)])
func columnAfter(scalar: Unicode.Scalar, column: Int, expected: Int) {
    #expect(ScreenReader.column(after: scalar, at: column) == expected)
}

/// Near-white theme colors on a near-white card, where the floor moves the theme's own colors too.
private let lightCard = Theme.Palette(
    background: 0xF8F8F7, foreground: 0x262626, caret: 0, selection: 0,
    ansi: (0..<16).map { 0xF0F0F0 - UInt32($0) }
)

@Test("A captured cell takes the program's colors as the terminal draws them, its text then kept readable", arguments: [
    (CellStyle(), 0x262626, 0xF8F8F7),
    (CellStyle(foreground: .indexed(1)), 0xF0F0EF, 0xF8F8F7),
    // Bold brightens the first seven colors, as SwiftTerm does, and leaves the eighth alone.
    (CellStyle(foreground: .indexed(1), bold: true), 0xF0F0E7, 0xF8F8F7),
    (CellStyle(foreground: .indexed(7), bold: true), 0xF0F0E9, 0xF8F8F7),
    // Inverse swaps the colors, the defaults included.
    (CellStyle(inverse: true), 0xF8F8F7, 0x262626),
    (CellStyle(foreground: .indexed(1), inverse: true), 0xF8F8F7, 0xF0F0EF),
    // The color cube, the gray ramp and 24-bit colors.
    (CellStyle(foreground: .indexed(16 + 36 * 5 + 6 * 1 + 2)), 0xFF5F87, 0xF8F8F7),
    (CellStyle(foreground: .rgb(1, 2, 3), background: .indexed(232)), 0x010203, 0x080808),
    // Faint fades halfway into the background before the floor, as SwiftTerm dims before Lhûn adjusts.
    (CellStyle(faint: true), 0x8F8F8E, 0xF8F8F7),
] as [(CellStyle, UInt32, UInt32)])
func cellColors(style: CellStyle, shape: UInt32, background: UInt32) {
    let colors = lightCard.colors(of: style)
    #expect(colors.shape == shape)
    #expect(colors.background == background)
    #expect(colors.text == Contrast.readable(shape, on: background))
}
