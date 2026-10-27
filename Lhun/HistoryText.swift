import CoreText
import SwiftTerm
import UIKit

/// The text behind the history overlay (HistoryView): a capture or the screen read into rows, those rows
/// drawn in the terminal's own cells, fonts and colors, and the text a copy puts on the clipboard.
enum HistoryText {
    /// Ends a row whose line goes on in the next row, where tmux wrapped it. A copy joins the two again.
    static let wrap: Character = "\u{2028}"
    /// Ends a row that ends its line.
    static let lineEnd: Character = "\n"

    /// What copying `selection` puts on the clipboard: wrapped rows joined back into their lines, and no
    /// blanks at the end of a line.
    static func copied(_ selection: Substring) -> String {
        selection.split(separator: lineEnd, omittingEmptySubsequences: false).map { line in
            var line = String(line.filter { $0 != wrap })
            while line.last == " " { line.removeLast() }
            return line
        }.joined(separator: String(lineEnd))
    }

    /// Columns a character takes on the terminal.
    static func cells(_ character: Character) -> Int {
        character.unicodeScalars.first.map(ScreenReader.cellWidth) ?? 0
    }

    struct Prompts {
        let history: Int
        let width: Int
        let rows: [Int]

        init?(_ output: String) {
            guard let newline = output.firstIndex(of: "\n") else { return nil }
            let header = output[..<newline].split(separator: " ")
            guard header.count == 2, let history = Int(header[0]), let width = Int(header[1]) else { return nil }
            var rows: [Int] = []
            for line in output[output.index(after: newline)...].split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 2)
                guard fields.count >= 2, let row = Int(fields[0]) else { return nil }
                if fields[1].contains("P") { rows.append(row) }
            }
            self.history = history
            self.width = width
            self.rows = rows
        }
    }

    /// A capture read into the pane's rows, oldest first.
    ///
    /// `capture-pane -J` joins each wrapped line into one, so the lines are cut again here at the pane's
    /// width, where tmux wrapped them: a character that would cross the edge starts the next row, and a
    /// tab reaches the next tab stop, or the last column when no stop is left, as tmux moves the cursor.
    struct Rows {
        /// Each row's runs.
        private(set) var rows: [[StyledRun]] = []
        /// Whether each row's line goes on in the row after it.
        private(set) var wraps: [Bool] = []

        /// `capture` is what `capture-pane -p -e -J` printed: lines that each end in a newline.
        init(_ capture: Substring, width: Int) {
            var body = capture
            if body.last == "\n" { body = body.dropLast() }
            // Every capture starts in the default style, so each gets a reader of its own.
            var reader = ScreenReader()
            for line in reader.lines(body.unicodeScalars) {
                cut(line, width: max(width, 1))
            }
        }

        /// The screen as the terminal holds it, a row for each of its rows, for laying the screen itself
        /// over the terminal. As in a capture, a row whose line ends there leaves off the blanks after its
        /// last character.
        init(screen terminal: Terminal) {
            for row in 0..<terminal.rows {
                var runs: [StyledRun] = []
                if let line = terminal.getLine(row: row) {
                    for column in 0..<min(line.count, terminal.cols) {
                        let cell = line[column]
                        // The second half of a wide character holds nothing of its own.
                        guard cell.width > 0 else { continue }
                        let character = terminal.getCharacter(for: cell)
                        let text = character == "\0" ? " " : String(character)
                        let style = Self.style(of: cell.attribute)
                        if runs.last?.style == style {
                            runs[runs.count - 1].text += text
                        } else {
                            runs.append(StyledRun(text: text, style: style))
                        }
                    }
                }
                let wraps = terminal.getLine(row: row + 1)?.isWrapped ?? false
                rows.append(wraps ? runs : Self.trimmed(runs))
                self.wraps.append(wraps)
            }
        }

        /// A row's characters, colors aside.
        static func text(of row: [StyledRun]) -> String {
            row.reduce(into: "") { $0 += $1.text }
        }

        /// Takes off the last row when its text is `row`. Each stretch read after the first ends with the
        /// row the text below it starts with, so the two join where tmux had them. Returns whether the row
        /// now last goes on into the text below: false when nothing matched, which keeps every row.
        mutating func dropLast(matching row: String) -> Bool {
            guard let last = rows.last, Self.text(of: last) == row else { return false }
            rows.removeLast()
            wraps.removeLast()
            return wraps.last ?? false
        }

        private mutating func cut(_ line: [StyledRun], width: Int) {
            var row: [StyledRun] = []
            var column = 0
            for run in line {
                var text = ""
                for character in run.text {
                    if character == "\t" {
                        let stop = min(ScreenReader.column(after: "\t", at: column), width - 1)
                        text += String(repeating: " ", count: max(stop - column, 0))
                        column = max(stop, column)
                        continue
                    }
                    let cells = HistoryText.cells(character)
                    if column + cells > width, column > 0 {
                        if !text.isEmpty { row.append(StyledRun(text: text, style: run.style)) }
                        rows.append(row)
                        wraps.append(true)
                        row = []
                        text = ""
                        column = 0
                    }
                    text.append(character)
                    column += cells
                }
                if !text.isEmpty { row.append(StyledRun(text: text, style: run.style)) }
            }
            rows.append(row)
            wraps.append(false)
        }

        /// Leaves off the blanks at the end of a row that show nothing: spaces with no background, no
        /// inverse and no line through or under them.
        private static func trimmed(_ row: [StyledRun]) -> [StyledRun] {
            var row = row
            while let last = row.last, last.style.background == .default, !last.style.inverse,
                  !last.style.underline, !last.style.strikethrough {
                var text = last.text
                while text.last == " " { text.removeLast() }
                guard text.isEmpty else {
                    row[row.count - 1].text = text
                    break
                }
                row.removeLast()
            }
            return row
        }

        /// A cell's look in SwiftTerm, in a capture's terms.
        private static func style(of attribute: Attribute) -> CellStyle {
            let flags = attribute.style
            return CellStyle(
                foreground: color(attribute.fg),
                background: color(attribute.bg),
                bold: flags.contains(.bold),
                faint: flags.contains(.dim),
                italic: flags.contains(.italic),
                underline: flags.contains(.underline),
                inverse: flags.contains(.inverse),
                hidden: flags.contains(.invisible),
                strikethrough: flags.contains(.crossedOut)
            )
        }

        private static func color(_ color: Attribute.Color) -> TerminalColor {
            switch color {
            case .ansi256(let code): .indexed(code)
            case .trueColor(let red, let green, let blue): .rgb(red, green, blue)
            // A cell holds the inverted default only where nothing set its colors (`Attribute.empty`);
            // SwiftTerm swaps colors for inverse at drawing time, from the cell's inverse flag.
            case .defaultColor, .defaultInvertedColor: .default
            }
        }
    }

    /// Draws rows as the terminal does: in its fonts at its size, each character across its own cells,
    /// in the colors SwiftTerm gives the same cells.
    struct Style {
        let cell: CGSize
        private let fonts: Theme.TerminalFonts
        private let palette: Theme.Palette
        private let paragraph: NSParagraphStyle
        private var styles: [Ink: [NSAttributedString.Key: Any]] = [:]
        /// Each character's own advance in each face, measured once.
        private var advances: [Glyph: CGFloat] = [:]

        /// A style, and whether it draws block elements and Powerline separators, which keep the program's
        /// own color.
        private struct Ink: Hashable {
            let style: CellStyle
            let shape: Bool
        }

        private struct Glyph: Hashable {
            let character: Character
            let bold: Bool
            let italic: Bool
        }

        init(cell: CGSize, fonts: Theme.TerminalFonts, palette: Theme.Palette) {
            self.cell = cell
            self.fonts = fonts
            self.palette = palette
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = cell.height
            paragraph.maximumLineHeight = cell.height
            // Rows arrive cut to the pane's width; nothing here wraps them again.
            paragraph.lineBreakMode = .byClipping
            self.paragraph = paragraph
        }

        /// The rows as text. Each row ends in `HistoryText.wrap` or `HistoryText.lineEnd`, as its line goes
        /// on or not, except the last, which ends in `last` when text follows it.
        mutating func text(_ rows: Rows, endingWith last: Character?) -> NSAttributedString {
            let text = NSMutableAttributedString()
            let plain = attributes(for: CellStyle(), shape: false)
            for (index, row) in rows.rows.enumerated() {
                for run in row { append(run, to: text) }
                let end = index < rows.rows.count - 1 ? (rows.wraps[index] ? HistoryText.wrap : HistoryText.lineEnd) : last
                if let end { text.append(NSAttributedString(string: String(end), attributes: plain)) }
            }
            // After a final line break the text system adds a line of its own height, not a row's. A blank
            // makes an empty last row a row like the others; a copy leaves it off.
            if last == nil, rows.rows.last?.isEmpty == true {
                text.append(NSAttributedString(string: " ", attributes: plain))
            }
            return text
        }

        /// Adds a run, spaced so that each character covers exactly its cells.
        private mutating func append(_ run: StyledRun, to text: NSMutableAttributedString) {
            var piece = ""
            var spacing: CGFloat = 0
            var shape = false
            for character in run.text {
                let after = self.spacing(after: character, bold: run.style.bold, italic: run.style.italic)
                let isShape = Theme.Palette.isShape(character)
                if after != spacing || isShape != shape, !piece.isEmpty {
                    let attributes = attributes(for: run.style, shape: shape)
                    text.append(NSAttributedString(string: piece, attributes: attributes.merging([.kern: spacing]) { $1 }))
                    piece = ""
                }
                spacing = after
                shape = isShape
                piece.append(character)
            }
            guard !piece.isEmpty else { return }
            let attributes = attributes(for: run.style, shape: shape)
            text.append(NSAttributedString(string: piece, attributes: attributes.merging([.kern: spacing]) { $1 }))
        }

        /// What to add after `character` for it to fill its cells.
        private mutating func spacing(after character: Character, bold: Bool, italic: Bool) -> CGFloat {
            let glyph = Glyph(character: character, bold: bold, italic: italic)
            let advance: CGFloat
            if let known = advances[glyph] {
                advance = known
            } else {
                // Core Text picks the same fallback font for a character the terminal's font lacks.
                let alone = NSAttributedString(string: String(character), attributes: [.font: font(bold: bold, italic: italic)])
                advance = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(alone), nil, nil, nil))
                advances[glyph] = advance
            }
            return CGFloat(HistoryText.cells(character)) * cell.width - advance
        }

        private mutating func attributes(for style: CellStyle, shape: Bool) -> [NSAttributedString.Key: Any] {
            let key = Ink(style: style, shape: shape)
            if let known = styles[key] { return known }
            let colors = palette.colors(of: style)
            let ink = Theme.uiColor(colors.text)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(bold: style.bold, italic: style.italic),
                .foregroundColor: shape ? Theme.uiColor(colors.shape) : ink,
                .paragraphStyle: paragraph,
            ]
            if colors.background != palette.background {
                attributes[.backgroundColor] = Theme.uiColor(colors.background)
            }
            if style.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = ink
            }
            if style.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = ink
            }
            styles[key] = attributes
            return attributes
        }

        private func font(bold: Bool, italic: Bool) -> UIFont {
            switch (bold, italic) {
            case (true, true): fonts.boldItalic
            case (true, false): fonts.bold
            case (false, true): fonts.italic
            case (false, false): fonts.regular
            }
        }
    }

    /// The text system behind the overlay. Every row is exactly one cell tall, with its baseline where the
    /// terminal puts it, whatever fallback font a character on the row needs.
    final class Layout: NSObject, NSLayoutManagerDelegate {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        private let rowHeight: CGFloat
        private let baseline: CGFloat

        init(cell: CGSize, font: UIFont) {
            rowHeight = cell.height
            // SwiftTerm sets each row's baseline this far above the row's bottom (MetalTerminalRenderer).
            baseline = cell.height - ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
            super.init()
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            manager.delegate = self
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            lineFragmentRect.pointee.size.height = rowHeight
            lineFragmentUsedRect.pointee.size.height = rowHeight
            baselineOffset.pointee = baseline
            return true
        }
    }
}

extension Tmux {
    static func historyPrompts(_ name: String) -> String {
        let pane = quote("=" + name + ":")
        return prelude + #"tmux display -p -t \#(pane) '#{history_size} #{pane_width}' \; capture-pane -p -F -L -S - -E - -t \#(pane)"#
    }
}
