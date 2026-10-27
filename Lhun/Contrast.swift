import Foundation

/// A color in Oklab (Björn Ottosson, 2020): `l` is perceived lightness from 0 (black) to 1 (white);
/// `a` and `b` carry hue and chroma.
struct Oklab: Equatable {
    var l: Double
    var a: Double
    var b: Double

    /// From a 0xRRGGBB sRGB color.
    init(rgb: UInt32) {
        let r = Self.linear(rgb >> 16 & 0xFF), g = Self.linear(rgb >> 8 & 0xFF), b = Self.linear(rgb & 0xFF)
        let lms = (
            cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b),
            cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b),
            cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        )
        l = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
        a = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
        self.b = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
    }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// The nearest 0xRRGGBB sRGB color with this lightness and hue. When the color lies outside sRGB,
    /// chroma is reduced until it fits, so lightness and hue survive the trip.
    var rgb: UInt32 {
        var fitting = 0.0, scale = 1.0
        if !Self.inGamut(linearRGB(chroma: 1)) {
            scale = 0.5
            var outside = 1.0
            // Gray (no chroma) is always inside, so the boundary lies between `fitting` and `outside`.
            for _ in 0..<24 {
                if Self.inGamut(linearRGB(chroma: scale)) { fitting = scale } else { outside = scale }
                scale = (fitting + outside) / 2
            }
            scale = fitting
        }
        let (r, g, b) = linearRGB(chroma: scale)
        return Self.encode(r) << 16 | Self.encode(g) << 8 | Self.encode(b)
    }

    private func linearRGB(chroma scale: Double) -> (Double, Double, Double) {
        let a = self.a * scale, b = self.b * scale
        let lms = (
            pow(l + 0.3963377774 * a + 0.2158037573 * b, 3),
            pow(l - 0.1055613458 * a - 0.0638541728 * b, 3),
            pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        )
        return (
            4.0767416621 * lms.0 - 3.3077115913 * lms.1 + 0.2309699292 * lms.2,
            -1.2684380046 * lms.0 + 2.6097574011 * lms.1 - 0.3413193965 * lms.2,
            -0.0041960863 * lms.0 - 0.7034186147 * lms.1 + 1.7076147010 * lms.2
        )
    }

    /// Allows the rounding error of the matrices; `encode` clamps what is left.
    private static func inGamut(_ c: (Double, Double, Double)) -> Bool {
        let range = -1e-6...(1 + 1e-6)
        return range.contains(c.0) && range.contains(c.1) && range.contains(c.2)
    }

    private static func linear(_ channel: UInt32) -> Double {
        let c = Double(channel) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ linear: Double) -> UInt32 {
        let c = min(max(linear, 0), 1)
        let gamma = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt32((gamma * 255).rounded())
    }
}

/// Keeps every color text is drawn in readable on what it sits on, as Ghostty's `minimum-contrast` does, but
/// keeping the hue where Ghostty turns the text black or white. A foreground whose Oklab lightness sits within
/// the gap of its background moves to exactly that gap, darker on a light background and lighter on a dark
/// one, with its hue and chroma kept. A color already far enough away stays exactly as it is.
struct Contrast {
    /// About 4:1 in WCAG terms on either Mies card, so dark Mies's bright black (2.6:1) and dim text read.
    static let minimumGap = 0.4
    /// The gaps for a card without the focus, whose terminal sits under the card's dim (`CardSurface`): wide
    /// enough that text there, faint text included, still reads at 3:1 through the dim on every theme and
    /// tint. The dim flattens a light card more, so its gap is the wider.
    static let dimmedGap = (light: 0.63, dark: 0.55)

    static func readable(_ foreground: UInt32, on background: UInt32, dimmed: Bool = false) -> UInt32 {
        let fg = Oklab(rgb: foreground), bg = Oklab(rgb: background)
        let light = bg.l > 0.5
        let gap = dimmed ? (light ? dimmedGap.light : dimmedGap.dark) : minimumGap
        guard abs(fg.l - bg.l) < gap else { return foreground }
        let target = light ? max(bg.l - gap, 0) : min(bg.l + gap, 1)
        return Oklab(l: target, a: fg.a, b: fg.b).rgb
    }

    /// SwiftTerm already keeps one result per cell attribute; this keeps one per (color, background, dim)
    /// across attributes and across its cache resets, which happen on every theme or palette change.
    private var results: [UInt64: UInt32] = [:]
    private(set) var hits = 0
    private(set) var misses = 0

    mutating func cached(_ foreground: UInt32, on background: UInt32, dimmed: Bool) -> UInt32 {
        // Colors fill 24 bits, so the top bit is free for the dim.
        let key = UInt64(foreground) << 32 | UInt64(background) | (dimmed ? 1 << 63 : 0)
        if let result = results[key] {
            hits += 1
            return result
        }
        misses += 1
        // Truecolor output can name any number of colors; bound the table the way SwiftTerm bounds its own.
        if results.count >= 4096 { results.removeAll(keepingCapacity: true) }
        let result = Self.readable(foreground, on: background, dimmed: dimmed)
        results[key] = result
        return result
    }
}
