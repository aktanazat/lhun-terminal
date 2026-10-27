import SwiftTerm
import SwiftUI
import UIKit

/// Colors and fonts. The colors come from the chosen theme (Themes.swift, ThemeStore.swift): the
/// terminal takes the theme's palette, and the app around it takes surfaces made from the same colors.
enum Theme {
    struct Palette: Codable, Equatable, Sendable {
        let background: UInt32
        let foreground: UInt32
        let caret: UInt32
        let selection: UInt32
        let ansi: [UInt32]

        /// A light palette: colors a program picks are kept readable on it (Contrast.swift).
        var isLight: Bool { Oklab(rgb: background).l > 0.5 }
    }

    @MainActor
    static func apply(_ palette: Palette, dimmed: Bool, to view: TerminalView) {
        floor(view, dimmed: dimmed)
        view.installColors(palette.ansi.map { hex in
            // SwiftTerm colors are 16 bits per channel.
            SwiftTerm.Color(red: UInt16(hex >> 16 & 0xFF) * 257, green: UInt16(hex >> 8 & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
        })
        let background = uiColor(palette.background)
        view.nativeForegroundColor = uiColor(palette.foreground)
        view.nativeBackgroundColor = background
        view.layer.backgroundColor = background.cgColor
        view.caretColor = uiColor(palette.caret)
        view.caretTextColor = background
        view.selectedTextBackgroundColor = uiColor(palette.selection)
    }

    /// Every color text is drawn in keeps a readable distance from what it sits on, on every theme and in
    /// both appearances: palette, 256-color and truecolor alike, dim included (Contrast.swift). In a card
    /// without the focus the distance is wider, so its text still reads through the card's dim. Setting it
    /// redraws the terminal in the new colors.
    @MainActor
    static func floor(_ view: TerminalView, dimmed: Bool) {
        view.foregroundAdjuster = { foreground, background in
            MainActor.assumeIsolated { readable(foreground, on: background, dimmed: dimmed) }
        }
    }

    /// Contrast results, one per (color, background, dim) (Contrast.swift).
    @MainActor private(set) static var contrast = Contrast()

    @MainActor
    private static func readable(_ foreground: UIColor, on background: UIColor, dimmed: Bool) -> UIColor {
        let color = hex(foreground)
        let result = contrast.cached(color, on: hex(background), dimmed: dimmed)
        return result == color ? foreground : uiColor(result)
    }

    static func hex(_ color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ c: CGFloat) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// The flat wash everything sits on.
    @MainActor static var wash: SwiftUI.Color { ThemeStore.shared.chrome.wash }
    /// The terminal card, in the terminal's own background.
    @MainActor static var card: SwiftUI.Color { ThemeStore.shared.chrome.card }
    /// The open session's pill and the palette, lifted off the wash.
    @MainActor static var raised: SwiftUI.Color { ThemeStore.shared.chrome.raised }
    /// Pills that are not open, and the highlighted palette row.
    @MainActor static var pill: SwiftUI.Color { ThemeStore.shared.chrome.pill }
    @MainActor static var hairline: SwiftUI.Color { ThemeStore.shared.chrome.hairline }
    /// Small descriptions, readable on the wash, cards, pills and highlighted rows.
    @MainActor static var detail: SwiftUI.Color { ThemeStore.shared.chrome.detail }

    struct TerminalFonts {
        let regular: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
    }

    /// The terminal's four faces at `size`, in the font chosen from the palette unless another is named.
    static func terminalFonts(size: CGFloat, font: TerminalFont = .chosen) -> TerminalFonts {
        TerminalFonts(
            regular: font.font(.regular, size: size) as UIFont,
            bold: font.font(.bold, size: size) as UIFont,
            italic: font.font(.italic, size: size) as UIFont,
            boldItalic: font.font(.boldItalic, size: size) as UIFont
        )
    }

    static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Lhûn's one grid: 8 pt steps, one inset, one corner radius.
enum Metrics {
    /// The screen's edge to its content, and a card's edge to its text.
    static let inset: CGFloat = 16
    /// Between two cards. Tests pin 8.
    static let gutter: CGFloat = 8
    /// Inside one inline group only, such as an icon and its label.
    static let tight: CGFloat = 4
    /// Between things in one group.
    static let near: CGFloat = 8
    /// Between one group and the next.
    static let apart: CGFloat = 16
    /// The next step past `apart`.
    static let wide: CGFloat = 24
    /// Around a lone sentence.
    static let section: CGFloat = 32
    /// Every rounded surface Lhûn draws.
    static let radius: CGFloat = 12
    /// Rows sit this far inside their card, so their highlight's radius is `radius(inside: 4)`, 8.
    static let rowInset: CGFloat = 4
    /// The smallest touch target.
    static let touch: CGFloat = 44
    /// A shape `padding` inside a rounded surface keeps its corners concentric.
    static func radius(inside padding: CGFloat) -> CGFloat { max(radius - padding, 0) }
}

extension View {
    /// The one shadow, for overlays that float over the cards: palette family, hover picture, dictation bubble.
    func lifted() -> some View { shadow(color: .black.opacity(0.18), radius: 24, y: 8) }
}
