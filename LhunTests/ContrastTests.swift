import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import LhunKit

/// Light Mies card and dark Mies card (Themes.swift).
private let lightCard: UInt32 = 0xF8F8F7
private let darkCard: UInt32 = 0x0E0E0E

private func hue(_ c: Oklab) -> Double { atan2(c.b, c.a) * 180 / .pi }
private func chroma(_ c: Oklab) -> Double { (c.a * c.a + c.b * c.b).squareRoot() }

/// Dim text as SwiftTerm hands it to the floor: halfway from its color to the background.
private func dimmed(_ color: UInt32, on background: UInt32) -> UInt32 {
    [16, 8, 0].reduce(UInt32(0)) { result, shift in
        result | (((color >> shift & 0xFF) + (background >> shift & 0xFF) + 1) / 2) << shift
    }
}

private func hex(_ color: UIColor) -> UInt32 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b].reduce(UInt32(0)) { $0 << 8 | UInt32(($1 * 255).rounded()) }
}

/// Reference values from Björn Ottosson's Oklab post (bottom table, sRGB primaries).
@Test(arguments: [
    (UInt32(0xFFFFFF), 1.000000, 0.000000, 0.000000),
    (UInt32(0xFF0000), 0.627955, 0.224863, 0.125846),
    (UInt32(0x00FF00), 0.866440, -0.233888, 0.179498),
    (UInt32(0x0000FF), 0.452014, -0.032457, -0.311528),
])
func oklabMatchesPublishedValues(rgb: UInt32, l: Double, a: Double, b: Double) {
    let c = Oklab(rgb: rgb)
    #expect(abs(c.l - l) < 1e-4)
    #expect(abs(c.a - a) < 1e-4)
    #expect(abs(c.b - b) < 1e-4)
}

/// Every sRGB color on a grid of every 15th channel value survives sRGB -> Oklab -> sRGB unchanged.
@Test(arguments: Array(stride(from: UInt32(0), through: 255, by: 15)))
func roundTripIsExact(red: UInt32) {
    var changed: [String] = []
    for green in stride(from: UInt32(0), through: 255, by: 15) {
        for blue in stride(from: UInt32(0), through: 255, by: 15) {
            let rgb = red << 16 | green << 8 | blue
            let back = Oklab(rgb: rgb).rgb
            if back != rgb { changed.append(String(format: "%06X -> %06X", rgb, back)) }
        }
    }
    #expect(changed == [])
}

@Test func colorsFarEnoughFromTheBackgroundAreLeftAlone() {
    let bg = Oklab(rgb: lightCard).l
    let justReadable = Oklab(l: bg - Contrast.minimumGap - 0.01, a: 0.02, b: 0.05).rgb
    #expect(Contrast.readable(justReadable, on: lightCard) == justReadable)
    #expect(Contrast.readable(0x262626, on: lightCard) == 0x262626)
    #expect(Contrast.readable(0xD6D6D6, on: darkCard) == 0xD6D6D6)
}

@Test func colorsTooCloseToALightBackgroundDarkenToTheGap() {
    let bg = Oklab(rgb: lightCard).l
    let justUnreadable = Oklab(l: bg - Contrast.minimumGap + 0.02, a: 0.02, b: 0.05).rgb
    for fg in [justUnreadable, 0xFAF0B4, 0xD0D0D0, 0xFFFFFF] {
        let l = Oklab(rgb: Contrast.readable(fg, on: lightCard)).l
        #expect(abs(l - (bg - Contrast.minimumGap)) < 0.005, "\(String(fg, radix: 16)) ended at L \(l)")
    }
}

@Test func colorsTooCloseToADarkBackgroundLightenToTheGap() {
    let bg = Oklab(rgb: darkCard).l
    let l = Oklab(rgb: Contrast.readable(0x303050, on: darkCard)).l
    #expect(abs(l - (bg + Contrast.minimumGap)) < 0.005)
}

/// Pale yellow, light sky blue and pale pink fit sRGB at their new lightness, so hue and chroma both survive.
@Test(arguments: [UInt32(0xFAF0B4), 0xAFD7FF, 0xFFD7D7])
func correctionKeepsHueAndChroma(rgb: UInt32) {
    let before = Oklab(rgb: rgb)
    let after = Oklab(rgb: Contrast.readable(rgb, on: lightCard))
    #expect(abs(hue(after) - hue(before)) < 1.5)
    #expect(abs(chroma(after) - chroma(before)) < 0.004)
}

/// Pure yellow at a darker lightness lies outside sRGB: chroma gives way, hue does not.
@Test func outOfGamutResultKeepsHueAndLightness() {
    let bg = Oklab(rgb: lightCard).l
    let before = Oklab(rgb: 0xFFFF00)
    let after = Oklab(rgb: Contrast.readable(0xFFFF00, on: lightCard))
    #expect(abs(after.l - (bg - Contrast.minimumGap)) < 0.005)
    #expect(abs(hue(after) - hue(before)) < 1.5)
    #expect(chroma(after) < chroma(before))
}

/// Dark Mies's black and bright black sit at 1.1:1 and 2.6:1 on the dark card, and dim text lands halfway to
/// the card before the floor sees it. Each ends exactly at the floor.
@Test(arguments: [
    ("black", LhunTheme.mies(dark: true).palette.ansi[0]),
    ("bright black", LhunTheme.mies(dark: true).palette.ansi[8]),
    ("dim text", dimmed(LhunTheme.mies(dark: true).palette.foreground, on: darkCard)),
    ("dim bright black", dimmed(LhunTheme.mies(dark: true).palette.ansi[8], on: darkCard)),
])
func darkGreysAndDimTextReachTheFloor(name: String, color: UInt32) {
    let bg = Oklab(rgb: darkCard).l
    let l = Oklab(rgb: Contrast.readable(color, on: darkCard)).l
    #expect(abs(l - (bg + Contrast.minimumGap)) < 0.005, "\(name) ended at L \(l)")
}

/// Every other dark Mies color already reads, so the floor leaves it exactly as it is.
@Test func darkMiesColorsThatReadAreUntouched() {
    let palette = LhunTheme.mies(dark: true).palette
    let reading = [palette.foreground] + palette.ansi.indices.filter { $0 != 0 && $0 != 8 }.map { palette.ansi[$0] }
    let moved = reading.filter { Contrast.readable($0, on: palette.background) != $0 }
    #expect(moved.map { String($0, radix: 16) } == [])
}

/// Claude Code's orange (D97757) already reads on the dark card, about 6:1, so the live terminal and history
/// both draw it exactly as the program sent it.
@MainActor
@Test func readableOrangeIsUntouched() throws {
    let palette = LhunTheme.mies(dark: true).palette
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    Theme.apply(palette, dimmed: false, to: view)
    let adjust = try #require(view.foregroundAdjuster)
    #expect(hex(adjust(Theme.uiColor(0xD97757), Theme.uiColor(palette.background))) == 0xD97757)
    #expect(palette.colors(of: CellStyle(foreground: .rgb(0xD9, 0x77, 0x57))).text == 0xD97757)
}

/// Every theme, light and dark, hands the terminal's colors to the floor: text in the card's own color is
/// drawn the floor away from the card, a wider floor in a card without the focus, and the theme's foreground,
/// which reads, is drawn as it is.
@MainActor
@Test(arguments: (LhunTheme.list(dark: false) + LhunTheme.list(dark: true)).flatMap { [($0, false), ($0, true)] })
func everyThemeFloorsTheTerminal(theme: LhunTheme, dimmed: Bool) throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    let palette = theme.palette
    Theme.apply(palette, dimmed: dimmed, to: view)
    let adjust = try #require(view.foregroundAdjuster)
    let card = Theme.uiColor(palette.background)
    let hidden = hex(adjust(card, card))
    let gap = abs(Oklab(rgb: hidden).l - Oklab(rgb: palette.background).l)
    let floor = dimmed ? (palette.isLight ? Contrast.dimmedGap.light : Contrast.dimmedGap.dark) : Contrast.minimumGap
    #expect(abs(gap - floor) < 0.005, "\(theme.name): the card's color was drawn as \(String(hidden, radix: 16))")
    #expect(hex(adjust(Theme.uiColor(palette.foreground), card)) == palette.foreground)
}
