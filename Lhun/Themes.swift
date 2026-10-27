import Foundation

/// A theme: a terminal palette with a name. Mies is Lhûn's own and the default; the others are soft
/// and muted in the same spirit, each light one kept as readable as Mies. The app around the terminal
/// takes its colors from the same theme (`Surfaces`). A theme imported from a Ghostty theme file keeps an
/// id of its own and is not in these lists (ThemeStore.swift).
struct LhunTheme: Codable, Equatable, Identifiable, Sendable {
    /// Saved as the choice. Mies keeps one id for its light and dark palettes.
    let id: String
    let name: String
    let palette: Theme.Palette
    /// Mies sets the raised color Lhûn has always had; every other theme makes it from its background.
    var raised: UInt32?

    /// The id the Mac's Ghostty theme is saved under.
    static let ghosttyID = "ghostty"

    static func mies(dark: Bool) -> LhunTheme {
        dark ? miesDark : miesLight
    }

    /// The themes for one appearance: Mies, then the rest by name.
    static func list(dark: Bool) -> [LhunTheme] {
        dark ? darkList : lightList
    }

    /// One of Lhûn's own themes by its id.
    static func named(_ id: String, dark: Bool) -> LhunTheme? {
        list(dark: dark).first { $0.id == id }
    }

    private static let miesLight = LhunTheme(
        id: "mies", name: "Mies",
        palette: Theme.Palette(
            background: 0xF8F8F7, foreground: 0x262626, caret: 0x1A1A1A, selection: 0xE2E2E0,
            ansi: [
                0x262626, 0xA05050, 0x547B54, 0x8E7340, 0x596B80, 0x746178, 0x4D7676, 0xD8D8D6,
                0x8A8A8A, 0xB66A6A, 0x6A906A, 0xA18B50, 0x718399, 0x8A7690, 0x5F8B8B, 0xFFFFFF,
            ]
        ),
        raised: 0xFFFFFF
    )

    private static let miesDark = LhunTheme(
        id: "mies", name: "Mies",
        palette: Theme.Palette(
            background: 0x0E0E0E, foreground: 0xD6D6D6, caret: 0xEAEAEA, selection: 0x2E2E2E,
            ansi: [
                0x1B1B1B, 0xC47A7A, 0x7FA37F, 0xBFA46F, 0x8C9CB2, 0xA292AE, 0x83A3A3, 0xB8B8B8,
                0x545454, 0xD69292, 0x97BC97, 0xD2BB88, 0xA5B5CB, 0xBBAECA, 0x9CBDBD, 0xF2F2F2,
            ]
        ),
        raised: 0x2B2B2E
    )

    private static let lightList: [LhunTheme] = [
        miesLight,
        LhunTheme(
            id: "apricot-kiln", name: "Apricot Kiln",
            palette: Theme.Palette(
                background: 0xFFF3E8, foreground: 0x3E2C22, caret: 0x341E11, selection: 0xEFD8C5,
                ansi: [
                    0x3E2C22, 0x9F5246, 0x4E7C50, 0x926B32, 0x4D6D91, 0x7C5D83, 0x407A7B, 0xE6D2C1,
                    0x908479, 0xB66A5E, 0x669267, 0xA8814C, 0x6483A6, 0x927499, 0x599091, 0xFFFDFB,
                ]
            )
        ),
        LhunTheme(
            id: "blush-atelier", name: "Blush Atelier",
            palette: Theme.Palette(
                background: 0xFFF2F3, foreground: 0x3E2A2D, caret: 0x351C20, selection: 0xEFD6D8,
                ansi: [
                    0x3E2A2D, 0x9D5256, 0x507B51, 0x8C6E34, 0x4E6D8F, 0x855B75, 0x43797A, 0xE4D0D2,
                    0x8E8384, 0xB3696C, 0x689168, 0xA2844E, 0x6583A5, 0x9B728B, 0x5C8F90, 0xFFFDFD,
                ]
            )
        ),
        LhunTheme(
            id: "celadon-day", name: "Celadon Day",
            palette: Theme.Palette(
                background: 0xECF8F0, foreground: 0x21322B, caret: 0x0F271D, selection: 0xCCE2D4,
                ansi: [
                    0x21322B, 0x9B5453, 0x4D7B57, 0x8B6E38, 0x506D8D, 0x7A5F81, 0x477975, 0xC8DBCF,
                    0x7E8982, 0xB16B69, 0x65916E, 0xA08552, 0x6783A3, 0x907596, 0x5F8F8A, 0xFAFFFC,
                ]
            )
        ),
        LhunTheme(
            id: "rice-paper", name: "Rice Paper",
            palette: Theme.Palette(
                background: 0xFAF7F1, foreground: 0x2D2823, caret: 0x241B12, selection: 0xE5DECE,
                ansi: [
                    0x2D2823, 0x9E5251, 0x507B51, 0x8C6E34, 0x4E6D8F, 0x7B5E82, 0x43797A, 0xDAD5CB,
                    0x89867E, 0xB46A68, 0x689168, 0xA2844E, 0x6583A5, 0x917497, 0x5C8F90, 0xFFFDFA,
                ]
            )
        ),
        LhunTheme(
            id: "sand-dollar", name: "Sand Dollar",
            palette: Theme.Palette(
                background: 0xFAF4E1, foreground: 0x3A3221, caret: 0x2F250E, selection: 0xE4DBBE,
                ansi: [
                    0x3A3221, 0x9B5453, 0x5E7849, 0x8B6E38, 0x4A6F8B, 0x7A5F81, 0x46797A, 0xDFD6BA,
                    0x8C8675, 0xB16B69, 0x758E60, 0xA08552, 0x6185A1, 0x907596, 0x5E8F8F, 0xFFFDF9,
                ]
            )
        ),
        LhunTheme(
            id: "tidewater-day", name: "Tidewater Day",
            palette: Theme.Palette(
                background: 0xEDF7FD, foreground: 0x222F3E, caret: 0x122335, selection: 0xCCE0EC,
                ansi: [
                    0x222F3E, 0x9E5251, 0x507B51, 0x8C6E34, 0x4D6D8F, 0x7B5E82, 0x447882, 0xC9D8E2,
                    0x7F888D, 0xB46A68, 0x689168, 0xA2844E, 0x6483A4, 0x917497, 0x5D8E98, 0xFCFEFF,
                ]
            )
        ),
        LhunTheme(
            id: "wisteria-paper", name: "Wisteria Paper",
            palette: Theme.Palette(
                background: 0xF7F2FE, foreground: 0x332D3E, caret: 0x271F35, selection: 0xE0D7ED,
                ansi: [
                    0x332D3E, 0x9E5251, 0x507B51, 0x8C6E34, 0x5A6990, 0x795F84, 0x43797A, 0xDAD2E4,
                    0x88848F, 0xB46A68, 0x689168, 0xA2844E, 0x707FA6, 0x8F7599, 0x5C8F90, 0xFEFDFF,
                ]
            )
        ),
    ]

    private static let darkList: [LhunTheme] = [
        miesDark,
        LhunTheme(
            id: "celadon-night", name: "Celadon Night",
            palette: Theme.Palette(
                background: 0x101A15, foreground: 0xCFDBD1, caret: 0xE1EEE3, selection: 0x25382E,
                ansi: [
                    0x202B25, 0xCE8986, 0x83B08C, 0xC9AD79, 0x8AA6C6, 0xB296B8, 0x81AFAA, 0xB7C1B8,
                    0x5C6661, 0xE19F9C, 0x9AC4A2, 0xDDC292, 0xA0BAD9, 0xC5ABCB, 0x98C3BE, 0xEFF5F0,
                ]
            )
        ),
        LhunTheme(
            id: "ember-study", name: "Ember Study",
            palette: Theme.Palette(
                background: 0x1E150E, foreground: 0xE0D6C8, caret: 0xF2E8DA, selection: 0x402F23,
                ansi: [
                    0x30251E, 0xD0897D, 0x86B086, 0xCFAB77, 0x88A6C8, 0xB396B9, 0x7EAFB0, 0xC5BCB2,
                    0x6B615B, 0xE39F94, 0x9CC49D, 0xE2C090, 0x9EBADA, 0xC6ABCC, 0x96C3C3, 0xF8F3EC,
                ]
            )
        ),
        LhunTheme(
            id: "graphite-rain", name: "Graphite Rain",
            palette: Theme.Palette(
                background: 0x1A1C1E, foreground: 0xD5D8DB, caret: 0xE7EAED, selection: 0x313941,
                ansi: [
                    0x2A2D2F, 0xCA8C89, 0x8BAE8B, 0xC7AD80, 0x8CA6C3, 0xB098B6, 0x85AEAE, 0xBBBEC1,
                    0x606468, 0xDCA19F, 0xA1C2A1, 0xDAC298, 0xA2BAD5, 0xC4ADC9, 0x9BC2C2, 0xF2F4F5,
                ]
            )
        ),
        LhunTheme(
            id: "indigo-hour", name: "Indigo Hour",
            palette: Theme.Palette(
                background: 0x181729, foreground: 0xD6D6E5, caret: 0xE8E8F7, selection: 0x33324D,
                ansi: [
                    0x28283B, 0xD18885, 0x86B086, 0xCBAD76, 0x8FA4C9, 0xAA98C0, 0x7EAFB0, 0xBCBCC8,
                    0x616173, 0xE39E9B, 0x9CC49D, 0xDEC28F, 0xA4B8DC, 0xBEADD3, 0x96C3C3, 0xF2F3FA,
                ]
            )
        ),
        LhunTheme(
            id: "kelp-garden", name: "Kelp Garden",
            palette: Theme.Palette(
                background: 0x091C1B, foreground: 0xCADCD8, caret: 0xDCEEEA, selection: 0x1B3A39,
                ansi: [
                    0x1A2D2C, 0xCE8986, 0x87AF88, 0xC9AD79, 0x8AA6C6, 0xB296B8, 0x81AFAC, 0xB3C1BE,
                    0x576766, 0xE19F9C, 0x9EC39E, 0xDDC292, 0xA0BAD9, 0xC5ABCB, 0x98C3C0, 0xEDF6F4,
                ]
            )
        ),
        LhunTheme(
            id: "plum-cellar", name: "Plum Cellar",
            palette: Theme.Palette(
                background: 0x1E121D, foreground: 0xDED3E0, caret: 0xF0E5F2, selection: 0x3F2B3D,
                ansi: [
                    0x30232E, 0xD18885, 0x86B086, 0xCBAD76, 0x88A6C8, 0xB894B4, 0x7EAFB0, 0xC2BBC4,
                    0x6B5F69, 0xE39E9B, 0x9CC49D, 0xDEC28F, 0x9EBADA, 0xCBAAC7, 0x96C3C3, 0xF7F1F8,
                ]
            )
        ),
        LhunTheme(
            id: "tidewater-night", name: "Tidewater Night",
            palette: Theme.Palette(
                background: 0x101A27, foreground: 0xCDD9E2, caret: 0xDFEBF5, selection: 0x27364B,
                ansi: [
                    0x202B39, 0xD18885, 0x86B086, 0xCBAD76, 0x87A7C8, 0xB396B9, 0x7FAEB8, 0xB6BFC6,
                    0x5A6471, 0xE39E9B, 0x9CC49D, 0xDEC28F, 0x9DBBDA, 0xC6ABCC, 0x96C2CB, 0xEEF4F9,
                ]
            )
        ),
    ]
}

/// The colors of the app around the terminal, made from a theme: the wash everything sits on, the card
/// in the terminal's background, raised surfaces a step off the wash, and the ink of pills and lines.
struct Surfaces: Equatable, Sendable {
    /// One flat color: the card's own hue and chroma, a step darker in light and lighter in dark.
    var wash: UInt32
    var card: UInt32
    var raised: UInt32
    var pillInk: UInt32
    var pillOpacity: Double
    /// The lines between things, such as the one between two cards in the compact layout: the foreground,
    /// faint. Faint enough in light; on a dark card it needs more to show at all, and lands where Apple's
    /// dark separators do, about 1.6:1.
    var hairlineInk: UInt32
    var hairlineOpacity: Double

    init(_ theme: LhunTheme) {
        let palette = theme.palette
        let background = Oklab(rgb: palette.background)
        let light = palette.isLight
        // No edge is drawn around a card, so this step in lightness alone tells it from the wash, the way
        // Apple's grouped backgrounds do; the hue and chroma stay the background's own.
        wash = Oklab(l: background.l + (light ? -0.035 : 0.048), a: background.a, b: background.b).rgb
        raised = theme.raised ?? (light
            ? Oklab.color(min(background.l + 0.021, 1), background.chroma * 0.4, background.hue)
            : Oklab.color(background.l + 0.126, background.chroma + 0.004, background.hue))
        card = palette.background
        pillInk = palette.foreground
        pillOpacity = 0.05
        hairlineInk = palette.foreground
        hairlineOpacity = light ? 0.08 : 0.2
    }

    /// Small labels stay readable on every surface, including a highlighted row or an unopened pill.
    /// The faintest opaque gray meeting 4.5:1 in light or 5.3:1 in dark is made once with Chrome's colors.
    /// A host tint changes these surfaces too, so its detail color is derived from the tinted result.
    var detail: UInt32 {
        let light = Oklab(rgb: card).l > 0.5
        var backdrop = Self.luminance(card)
        func include(_ background: UInt32) {
            let plain = Self.luminance(background)
            func channel(_ shift: UInt32) -> UInt32 {
                let ink = Double(pillInk >> shift & 0xFF)
                let base = Double(background >> shift & 0xFF)
                return UInt32((ink * pillOpacity + base * (1 - pillOpacity)).rounded())
            }
            let pill = Self.luminance(channel(16) << 16 | channel(8) << 8 | channel(0))
            backdrop = light ? min(backdrop, plain, pill) : max(backdrop, plain, pill)
        }
        include(card)
        include(raised)
        include(wash)
        let target = light ? (backdrop + 0.05) / 4.5 - 0.05 : (backdrop + 0.05) * 5.3 - 0.05
        let linear = min(max(target, 0), 1)
        let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        // Round away from the background so an 8-bit channel never drops below the contrast floor.
        let byte = UInt32((encoded * 255).rounded(light ? .down : .up))
        return byte * 0x010101
    }

    /// WCAG relative luminance, after decoding sRGB's transfer function.
    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double(rgb >> shift & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// The theme colors a host's tint is taken from, best first. The server leans to cyan, blue and
    /// green; any other host to yellow and red, so two hosts never share a tint. Magenta is left out: on a
    /// wash it reads as purple.
    static func tintColors(for host: String) -> [Int] {
        host == Host.server.id ? [6, 4, 2] : [3, 1]
    }

    /// The least Oklab distance between a tinted wash and the plain one, so two hosts read apart at a
    /// glance.
    static let tintGap = 0.025

    /// These surfaces turned toward one of the theme's own colors, so a host reads apart at a glance
    /// while its terminal keeps the theme's colors. The color is the first of `colors` whose hue sits well
    /// away from the wash's, or failing that the one farthest from it, so the tint never melts into a
    /// wash of nearly the same hue. The tint is made stronger only as far as `tintGap` needs: more chroma
    /// first, then, where sRGB caps the chroma near white or black, a step toward the middle.
    func tinted(by colors: [Int], of palette: Theme.Palette) -> Surfaces {
        let plain = Oklab(rgb: wash)
        func apart(_ index: Int) -> Double {
            Self.hueDistance(Oklab(rgb: palette.ansi[index]).hue, plain.hue)
        }
        let accent = palette.ansi[colors.first { apart($0) >= 60 } ?? colors.max { apart($0) < apart($1) } ?? colors[0]]
        let hue = Oklab(rgb: accent).hue
        let light = palette.isLight
        var chroma = light ? 0.034 : 0.030
        var shade = 0.0
        func tint() -> UInt32 { Oklab.color(plain.l + (light ? -shade : shade), chroma, hue) }
        func close() -> Bool { Self.distance(Oklab(rgb: tint()), plain) < Self.tintGap }
        while chroma < 0.1, close() { chroma += 0.002 }
        while shade < 0.05, close() { shade += 0.002 }
        var tinted = self
        tinted.wash = tint()
        tinted.raised = Oklab.color(Oklab(rgb: raised).l, 0.012, hue)
        tinted.pillInk = accent
        tinted.pillOpacity = 0.12
        return tinted
    }

    private static func distance(_ x: Oklab, _ y: Oklab) -> Double {
        ((x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b)).squareRoot()
    }

    /// Degrees between two hues, 0 to 180.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// One value for the light appearance and one for the dark.
struct Pair<Value: Equatable & Sendable>: Equatable, Sendable {
    var light: Value
    var dark: Value

    subscript(dark dark: Bool) -> Value {
        get { dark ? self.dark : light }
        set {
            if dark { self.dark = newValue } else { light = newValue }
        }
    }
}

/// How one host's sessions look.
enum HostLook: Equatable, Sendable {
    /// Lhûn's theme, as it is.
    case lhun
    /// Lhûn's theme, with the wash and pills turned toward one of its colors.
    case tinted
    /// A theme of its own, the terminal's colors included.
    case theme(String)

    /// How the look is saved.
    var saved: String {
        switch self {
        case .lhun: "lhun"
        case .tinted: "tinted"
        case .theme(let id): "theme:" + id
        }
    }

    init?(saved: String) {
        switch saved {
        case "lhun": self = .lhun
        case "tinted": self = .tinted
        case let text where text.hasPrefix("theme:"): self = .theme(String(text.dropFirst(6)))
        default: return nil
        }
    }

    /// Unless he picks another, the server's surfaces carry a tint so its sessions never look like the
    /// Mac's.
    static func standard(for host: String) -> HostLook {
        host == Host.server.id ? .tinted : .lhun
    }
}

extension Oklab {
    var chroma: Double { (a * a + b * b).squareRoot() }

    /// In degrees.
    var hue: Double { atan2(b, a) * 180 / .pi }

    /// The 0xRRGGBB color at a lightness, chroma and hue in degrees, chroma reduced to fit sRGB.
    static func color(_ l: Double, _ chroma: Double, _ hue: Double) -> UInt32 {
        let radians = hue * .pi / 180
        return Oklab(l: min(max(l, 0), 1), a: chroma * cos(radians), b: chroma * sin(radians)).rgb
    }
}
