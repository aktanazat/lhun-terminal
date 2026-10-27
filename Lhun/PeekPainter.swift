import CoreGraphics
import CoreText
import Foundation

/// Draws a captured screen into a bitmap once, so a peek card shows a still picture instead of a
/// terminal. Core Text and Core Graphics only, so it runs off the main thread.
enum PeekPainter {
    /// The screen filling `size` points at `scale`: the terminal's background, then its cells on a grid
    /// scaled to fit, from the top left, in the terminal's font and the colors the terminal draws them in.
    static func picture(
        of screen: ScreenSnapshot, palette: Theme.Palette, font: TerminalFont, size: CGSize, scale: CGFloat
    ) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Points, from the top left. Text needs its own flip to stand upright.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        var colors: [UInt32: CGColor] = [:]
        func color(_ hex: UInt32) -> CGColor {
            if let known = colors[hex] { return known }
            let made = CGColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
            colors[hex] = made
            return made
        }
        context.setFillColor(color(palette.background))
        context.fill(CGRect(origin: .zero, size: size))

        let inset = min(size.width, size.height) * 0.03
        let face = Face(font)
        let grid = Self.grid(of: screen, in: face)
        let fontSize = min((size.width - 2 * inset) / grid.width, (size.height - 2 * inset) / grid.height)
        guard fontSize > 0 else { return context.makeImage() }
        let fonts = Fonts(font, size: fontSize)
        let advance = face.advance * fontSize
        let lineHeight = face.lineHeight * fontSize
        let ascent = face.ascent * fontSize
        let rule = max(fontSize / 14, 1 / scale)

        for (row, line) in screen.lines.enumerated() {
            let top = inset + CGFloat(row) * lineHeight
            var column = 0
            for run in line {
                let start = column
                column = run.text.unicodeScalars.reduce(start) { ScreenReader.column(after: $1, at: $0) }
                let style = run.style
                let colors = palette.colors(of: style)
                let box = CGRect(x: inset + CGFloat(start) * advance, y: top, width: CGFloat(column - start) * advance, height: lineHeight)
                if colors.background != palette.background {
                    context.setFillColor(color(colors.background))
                    context.fill(box)
                }
                guard !style.hidden, run.text.unicodeScalars.contains(where: { $0 != " " && $0 != "\t" }) else { continue }
                let ink: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): fonts.font(bold: style.bold, italic: style.italic),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(colors.text),
                ]
                // Block elements and Powerline separators keep the program's own color, as the terminal draws them.
                let split = colors.shape != colors.text
                let shapes = split ? ink.merging([NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(colors.shape)]) { $1 } : ink
                // A tab moves on to the next tab stop, so the text between tabs starts at its own column.
                var at = start
                for (index, piece) in run.text.split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
                    if index > 0 { at = ScreenReader.column(after: "\t", at: at) }
                    var from = piece.startIndex
                    while from < piece.endIndex {
                        let shape = split && Theme.Palette.isShape(piece[from])
                        let rest = piece[from...]
                        let to = split ? rest.firstIndex(where: { Theme.Palette.isShape($0) != shape }) ?? rest.endIndex : rest.endIndex
                        let part = piece[from..<to]
                        context.textPosition = CGPoint(x: inset + CGFloat(at) * advance, y: top + ascent)
                        let text = NSAttributedString(string: String(part), attributes: shape ? shapes : ink)
                        CTLineDraw(CTLineCreateWithAttributedString(text), context)
                        at = part.unicodeScalars.reduce(at) { ScreenReader.column(after: $1, at: $0) }
                        from = to
                    }
                }
                context.setFillColor(color(colors.text))
                if style.underline {
                    context.fill(CGRect(x: box.minX, y: top + ascent + rule * 1.5, width: box.width, height: rule))
                }
                if style.strikethrough {
                    context.fill(CGRect(x: box.minX, y: top + ascent - face.strikeHeight * fontSize, width: box.width, height: rule))
                }
            }
        }
        return context.makeImage()
    }

    /// The width over the height of the screen's grid in `font`: the shape a picture of it fills.
    static func aspect(of screen: ScreenSnapshot, font: TerminalFont) -> CGFloat {
        let grid = Self.grid(of: screen, in: Face(font))
        return grid.width / grid.height
    }

    /// The screen's cells at a font size of one point: every column, and every row tmux reported or
    /// printed.
    private static func grid(of screen: ScreenSnapshot, in face: Face) -> CGSize {
        CGSize(
            width: CGFloat(max(screen.columns, 1)) * face.advance,
            height: CGFloat(max(screen.rows, screen.lines.count, 1)) * face.lineHeight
        )
    }

    /// A font's measurements per point of font size.
    private struct Face {
        let advance: CGFloat
        let ascent: CGFloat
        let lineHeight: CGFloat
        /// Height of a strikethrough above the baseline: half the x-height.
        let strikeHeight: CGFloat

        init(_ terminalFont: TerminalFont) {
            let size: CGFloat = 100
            let font = terminalFont.font(.regular, size: size)
            var character: UniChar = 0x4D
            var glyph: CGGlyph = 0
            var advance = CGSize.zero
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let ascent = CTFontGetAscent(font)
            self.advance = advance.width / size
            self.ascent = ascent / size
            lineHeight = (ascent + CTFontGetDescent(font) + CTFontGetLeading(font)) / size
            strikeHeight = CTFontGetXHeight(font) / 2 / size
        }
    }

    /// The four faces at one size.
    private struct Fonts {
        let regular: CTFont
        let bold: CTFont
        let italic: CTFont
        let boldItalic: CTFont

        init(_ font: TerminalFont, size: CGFloat) {
            regular = font.font(.regular, size: size)
            bold = font.font(.bold, size: size)
            italic = font.font(.italic, size: size)
            boldItalic = font.font(.boldItalic, size: size)
        }

        func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
            switch (isBold, isItalic) {
            case (true, true): boldItalic
            case (true, false): bold
            case (false, true): italic
            case (false, false): regular
            }
        }
    }
}
