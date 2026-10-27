import Foundation

/// A color as `capture-pane -e` writes it.
enum TerminalColor: Hashable, Sendable {
    case `default`
    /// 0–15 are the theme's sixteen colors; 16–255 the xterm color cube and gray ramp.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// How a run of cells looks.
struct CellStyle: Hashable, Sendable {
    var foreground = TerminalColor.default
    var background = TerminalColor.default
    var bold = false
    var faint = false
    var italic = false
    var underline = false
    var inverse = false
    var hidden = false
    var strikethrough = false
}

/// Neighboring cells in one style. A tab stays in the text as `\t`; the column it reaches depends on the
/// column it starts at, which `ScreenReader.column(after:at:)` works out.
struct StyledRun: Equatable, Sendable {
    var text: String
    var style: CellStyle
}

/// Reads `capture-pane -e` text into styled runs. tmux writes SGR sequences, SO and SI around cells in the
/// line-drawing set, and a tab where the program wrote one; any other control or escape sequence is
/// skipped, never shown as text. A style carries from line to line, since tmux writes only what changes,
/// so each capture gets a reader of its own.
struct ScreenReader {
    private var style = CellStyle()
    private var lineDrawing = false

    mutating func lines(_ body: Substring.UnicodeScalarView) -> [[StyledRun]] {
        guard !body.isEmpty else { return [] }
        var lines: [[StyledRun]] = []
        var line: [StyledRun] = []
        var text = String.UnicodeScalarView()
        var index = body.startIndex
        while index < body.endIndex {
            let scalar = body[index]
            body.formIndex(after: &index)
            switch scalar.value {
            case 0x0A:
                end(&text, in: &line)
                lines.append(line)
                line = []
            case 0x1B:
                end(&text, in: &line)
                index = escape(body, at: index)
            case 0x0E:
                lineDrawing = true
            case 0x0F:
                lineDrawing = false
            case 0x09:
                text.append(scalar)
            case 0..<0x20, 0x7F:
                break
            default:
                text.append(lineDrawing ? Self.drawing[scalar] ?? scalar : scalar)
            }
        }
        end(&text, in: &line)
        lines.append(line)
        return lines
    }

    /// Closes the text so far as a run in the current style, joined to the last run when it matches.
    private func end(_ text: inout String.UnicodeScalarView, in line: inout [StyledRun]) {
        guard !text.isEmpty else { return }
        if let last = line.indices.last, line[last].style == style {
            line[last].text.unicodeScalars.append(contentsOf: text)
        } else {
            line.append(StyledRun(text: String(text), style: style))
        }
        text = String.UnicodeScalarView()
    }

    /// Reads the sequence after an ESC and returns where the text resumes.
    private mutating func escape(
        _ body: Substring.UnicodeScalarView, at start: Substring.UnicodeScalarView.Index
    ) -> Substring.UnicodeScalarView.Index {
        guard start < body.endIndex else { return start }
        var index = body.index(after: start)
        switch body[start] {
        case "[":
            // CSI: parameter and intermediate bytes, then one final byte. SGR is the one ending in m.
            let parameters = index
            while index < body.endIndex, (0x20...0x3F).contains(body[index].value) { body.formIndex(after: &index) }
            guard index < body.endIndex, (0x40...0x7E).contains(body[index].value) else { return index }
            if body[index] == "m" { applySGR(Substring(body[parameters..<index])) }
            return body.index(after: index)
        case "]", "P", "X", "^", "_":
            // OSC, DCS, SOS, PM and APC strings, such as OSC 8 links, run to BEL or to ST (ESC \).
            while index < body.endIndex {
                let scalar = body[index]
                body.formIndex(after: &index)
                if scalar == "\u{07}" { break }
                if scalar == "\u{1B}" {
                    if index < body.endIndex, body[index] == "\\" { body.formIndex(after: &index) }
                    break
                }
            }
            return index
        case "(", ")", "*", "+":
            // A character set designation names its set in one more byte.
            return index < body.endIndex ? body.index(after: index) : index
        default:
            return index
        }
    }

    /// Applies SGR parameters. Groups split on `;`, and a group with `:` carries its own sub-parameters:
    /// `4:3` is one curly underline, not an underline and an italic.
    private mutating func applySGR(_ parameters: Substring) {
        // A private marker, as in `CSI > 4 ; 1 m`, makes it some other sequence.
        if let first = parameters.unicodeScalars.first, (0x3C...0x3F).contains(first.value) { return }
        let groups = parameters.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        }
        var index = 0
        while index < groups.count {
            let group = groups[index]
            index += 1
            let code = group[0]
            if group.count > 1 {
                switch code {
                case 4: style.underline = group[1] != 0
                case 38: style.foreground = Self.color(group.dropFirst()) ?? style.foreground
                case 48: style.background = Self.color(group.dropFirst()) ?? style.background
                // 58 colors underlines and 5:3 is an overline; neither shows at a glance.
                default: break
                }
                continue
            }
            switch code {
            case 0: style = CellStyle()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4, 21: style.underline = true
            case 7: style.inverse = true
            case 8: style.hidden = true
            case 9: style.strikethrough = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 28: style.hidden = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(code - 82))
            case 100...107: style.background = .indexed(UInt8(code - 92))
            case 38, 48, 58:
                // 38;5;n and 38;2;r;g;b take the groups after them as arguments.
                let mode = index < groups.count ? groups[index][0] : 0
                let count = mode == 5 ? 2 : mode == 2 ? 4 : 1
                let arguments = groups[index..<min(index + count, groups.count)].map { $0[0] }
                index += arguments.count
                guard let color = Self.color(arguments[...]) else { break }
                if code == 38 { style.foreground = color }
                if code == 48 { style.background = color }
            default:
                break
            }
        }
    }

    /// `5, n` is a 256-color index, `2, r, g, b` a 24-bit color. The colon form may put a color space
    /// before r, so r, g and b are the last three.
    private static func color(_ arguments: ArraySlice<Int>) -> TerminalColor? {
        switch arguments.first {
        case 5? where arguments.count >= 2:
            return .indexed(UInt8(clamping: arguments[arguments.startIndex + 1]))
        case 2? where arguments.count >= 4:
            let rgb = arguments.suffix(3).map { UInt8(clamping: $0) }
            return .rgb(rgb[0], rgb[1], rgb[2])
        default:
            return nil
        }
    }

    /// Columns a character takes: two for wide East Asian characters and emoji, none for combining marks.
    static func cellWidth(_ scalar: Unicode.Scalar) -> Int {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// The column after `scalar` written at `column`, counting from 0: a tab moves on to the next multiple
    /// of 8, tmux's default tab stops, and any other character past the cells it takes.
    static func column(after scalar: Unicode.Scalar, at column: Int) -> Int {
        scalar == "\t" ? (column / 8 + 1) * 8 : column + cellWidth(scalar)
    }

    /// The DEC special graphics set, which tmux marks with SO and SI.
    private static let drawing = Dictionary(uniqueKeysWithValues: zip(
        "`abcdefghijklmnopqrstuvwxyz{|}~".unicodeScalars,
        "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars
    ))
}

extension Theme.Palette {
    /// The RGB value of a captured color: the theme's sixteen, then xterm's color cube and gray ramp.
    func hex(_ color: TerminalColor, default fallback: UInt32) -> UInt32 {
        switch color {
        case .default:
            return fallback
        case .indexed(let index) where index < 16:
            return ansi[Int(index)]
        case .indexed(let index) where index < 232:
            let cube = Int(index) - 16
            let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
            return levels[cube / 36] << 16 | levels[cube / 6 % 6] << 8 | levels[cube % 6]
        case .indexed(let index):
            let gray = UInt32(8 + (Int(index) - 232) * 10)
            return gray << 16 | gray << 8 | gray
        case .rgb(let red, let green, let blue):
            return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        }
    }

    /// A captured cell's colors as SwiftTerm draws them: inverse swaps the two, bold brightens the first
    /// seven colors, and faint text fades halfway into its background. The text then keeps a readable
    /// distance from what it sits on, as `Theme.apply` keeps it on every theme in both appearances;
    /// `shape` is its color before that, which block elements and Powerline separators keep.
    func colors(of style: CellStyle) -> (text: UInt32, shape: UInt32, background: UInt32) {
        var (ink, paper) = (style.foreground, style.background)
        var (inkDefault, paperDefault) = (foreground, background)
        if style.inverse {
            swap(&ink, &paper)
            swap(&inkDefault, &paperDefault)
        }
        if style.bold, case .indexed(let index) = ink, index < 7 { ink = .indexed(index + 8) }
        var shape = hex(ink, default: inkDefault)
        let behind = hex(paper, default: paperDefault)
        if style.faint { shape = Self.blend(shape, into: behind) }
        return (Contrast.readable(shape, on: behind), shape, behind)
    }

    /// Block elements and Powerline's solid and round separators: SwiftTerm draws them as shapes that meet
    /// the cells around them, in the program's own color rather than one kept readable.
    static func isShape(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x2580...0x259F, 0xE0B0, 0xE0B2, 0xE0B4, 0xE0B6: return true
        default: return false
        }
    }

    /// Halfway from a color to the one behind it: how faint text looks.
    private static func blend(_ color: UInt32, into background: UInt32) -> UInt32 {
        var mixed: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let channel = ((color >> shift & 0xFF) + (background >> shift & 0xFF)) / 2
            mixed |= channel << shift
        }
        return mixed
    }
}
