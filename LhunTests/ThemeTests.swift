import Foundation
import SwiftUI
import Testing
@testable import LhunKit

// MARK: The Mac's Ghostty config

@Test("The theme line of Ghostty's config names one theme for both appearances or one for each", arguments: [
    ("theme = Rose Pine", "Rose Pine", "Rose Pine"),
    ("theme = light:Rose Pine Dawn,dark:Rose Pine", "Rose Pine Dawn", "Rose Pine"),
    ("theme = dark: Nord , light: Nord Light", "Nord Light", "Nord"),
    ("theme = \"light:mies-light,dark:mies-dark\"", "mies-light", "mies-dark"),
    ("font-size = 13\ntheme = Nord\n# theme = Rose Pine\ntheme = Rose Pine Moon", "Rose Pine Moon", "Rose Pine Moon"),
])
func ghosttyThemeNames(config: String, light: String, dark: String) {
    #expect(GhosttyTheme.names(in: config) == GhosttyTheme.Names(light: light, dark: dark))
}

@Test("A config names no theme when it has no theme line, a later line clears it, or a pair lacks one side", arguments: [
    "font-size = 13",
    "# theme = Rose Pine",
    "theme = Rose Pine\ntheme =",
    "theme = light:Rose Pine Dawn",
    "theme = light:Rose Pine Dawn,dark:",
])
func ghosttyNoTheme(config: String) {
    #expect(GhosttyTheme.names(in: config) == nil)
}

private let rosePine = """
palette = 0=#26233a
palette = 1=#eb6f92
palette = 2=#31748f
palette = 3=#f6c177
palette = 4=#9ccfd8
palette = 5=#c4a7e7
palette = 6=#ebbcba
palette = 7=#e0def4
palette = 8=#6e6a86
palette = 9=#eb6f92
palette = 10=#31748f
palette = 11=#f6c177
palette = 12=#9ccfd8
palette = 13=#c4a7e7
palette = 14=#ebbcba
palette = 15=#e0def4
background = #191724
foreground = #e0def4
cursor-color = #e0def4
cursor-text = #191724
selection-background = #403d52
selection-foreground = #e0def4
"""

@Test("A Ghostty theme file reads as the colors it lists, with the config's own colors over them")
func ghosttyThemeColors() {
    let theme = GhosttyTheme.theme(
        named: "Rose Pine", file: rosePine, config: "theme = Rose Pine\nbackground = 101010\npalette = 1 = #FF0000", dark: true
    )
    #expect(theme.id == LhunTheme.ghosttyID)
    #expect(theme.name == "Rose Pine")
    #expect(theme.palette == Theme.Palette(
        background: 0x101010, foreground: 0xE0DEF4, caret: 0xE0DEF4, selection: 0x403D52,
        ansi: [
            0x26233A, 0xFF0000, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        ]
    ))
}

@Test("Colors a theme leaves out, or names in a way Lhûn can't read, come from Mies in the same appearance", arguments: [false, true])
func ghosttyThemeFallbacks(dark: Bool) {
    let mies = LhunTheme.mies(dark: dark).palette
    let theme = GhosttyTheme.theme(
        named: "Sparse", file: "background = black\nforeground = #123456\npalette = 2=#00ff00\npalette = 16=#ffffff", config: "",
        dark: dark
    )
    var ansi = mies.ansi
    ansi[2] = 0x00FF00
    #expect(theme.palette == Theme.Palette(
        background: mies.background, foreground: 0x123456, caret: 0x123456, selection: mies.selection, ansi: ansi
    ))
}

@Test("The themes the Mac printed are found by name, and one it found no file for is left out")
func ghosttyThemeFiles() {
    let output = "\u{1E}Rose Pine\n\(rosePine)\n\u{1E}mies-light\n\n"
    let files = GhosttyTheme.files(in: output)
    #expect(Array(files.keys) == ["Rose Pine"])
    #expect(files["Rose Pine"]?.contains("background = #191724") == true)
}

@MainActor
@Test("Importing a Ghostty file keeps its actual colors and gives it a stable identity")
func importedThemeFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lhun-theme-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("Rose Pine.theme")
    try Data(rosePine.utf8).write(to: file)
    let imported = try ThemeStore.shared.theme(fromFile: file)
    #expect(imported.id == GhosttyTheme.importedID(rosePine))
    #expect(imported.palette.background == 0x191724)
    #expect(!imported.palette.isLight)
    #expect(try ThemeStore.shared.theme(fromFile: file).id == imported.id)

    let light = folder.appendingPathComponent("New Light.theme")
    try Data("background=#ffffff\nforeground=#000000\n".utf8).write(to: light)
    #expect(try ThemeStore.shared.theme(fromFile: light).palette.isLight)
}

// MARK: Lhûn's themes

private let everyTheme = LhunTheme.list(dark: false).map { ($0, false) } + LhunTheme.list(dark: true).map { ($0, true) }

/// WCAG 2 contrast ratio.
private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double(rgb >> shift & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@Test("Every theme is listed under its own appearance and keeps its text and colors readable", arguments: everyTheme)
func themeReadable(theme: LhunTheme, dark: Bool) {
    let palette = theme.palette
    #expect(palette.isLight == !dark)
    #expect(contrast(palette.foreground, palette.background) >= 7)
    for index in 1...6 {
        #expect(contrast(palette.ansi[index], palette.background) >= 4.2, "color \(index)")
        #expect(contrast(palette.ansi[index + 8], palette.background) >= 3, "color \(index + 8)")
    }
}

@Test("Every theme's wash is its card's own color, a step darker in light and lighter in dark", arguments: everyTheme)
func washFollowsCard(theme: LhunTheme, dark: Bool) {
    let surfaces = Surfaces(theme)
    let (wash, card) = (Oklab(rgb: surfaces.wash), Oklab(rgb: surfaces.card))
    let colors = "wash \(String(format: "%06X", surfaces.wash)) by card \(String(format: "%06X", surfaces.card))"
    // No edge is drawn around a card, so this step alone tells the card from the wash.
    #expect((dark ? wash.l - card.l : card.l - wash.l) >= 0.03, "\(colors)")
    // The card's hue and chroma, to within an 8-bit channel's rounding: the wash leans to no other hue.
    #expect(abs(wash.a - card.a) < 0.004 && abs(wash.b - card.b) < 0.004, "\(colors)")
}

@Test("In every theme the server's wash and pills stand apart from the Mac's", arguments: everyTheme)
func serverTint(theme: LhunTheme, dark: Bool) {
    let mac = Surfaces(theme)
    let server = mac.tinted(by: Surfaces.tintColors(for: Host.server.id), of: theme.palette)
    let (a, b) = (Oklab(rgb: mac.wash), Oklab(rgb: server.wash))
    let distance = ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    #expect(distance >= 0.025, "wash \(String(format: "%06X", mac.wash)) and \(String(format: "%06X", server.wash))")
    #expect(server.pillInk != mac.pillInk)
}

@Test("Small labels meet their contrast floor on plain and tinted surfaces", arguments: everyTheme)
func detailReadable(theme: LhunTheme, dark: Bool) {
    let plain = Surfaces(theme)
    let variants = [plain] + [Host.mac.id, Host.server.id].map {
        plain.tinted(by: Surfaces.tintColors(for: $0), of: theme.palette)
    }
    for surfaces in variants {
        let detail = surfaces.detail
        for background in [surfaces.card, surfaces.raised, surfaces.wash] {
            // Composite the translucent pill in sRGB, independently of the implementation under test.
            var pill: UInt32 = 0
            for shift: UInt32 in [16, 8, 0] {
                let ink = Double(surfaces.pillInk >> shift & 255)
                let base = Double(background >> shift & 255)
                pill |= UInt32((ink * surfaces.pillOpacity + base * (1 - surfaces.pillOpacity)).rounded()) << shift
            }
            for surface in [background, pill] {
                #expect(contrast(detail, surface) >= (dark ? 5.3 : 4.5),
                        "detail \(String(format: "%06X", detail)) on \(String(format: "%06X", surface))")
            }
        }
        #expect(contrast(detail, surfaces.card) < contrast(theme.palette.foreground, surfaces.card),
                "details must stay quieter than the session name")
    }
}

@MainActor
@Test("An unfocused card dims its terminal and keeps its header's name and folder at the small-label floor",
      arguments: everyTheme)
func unfocusedHeaderReadable(theme: LhunTheme, dark: Bool) throws {
    let plain = Surfaces(theme)
    let variants = [plain] + [Host.mac.id, Host.server.id].map {
        plain.tinted(by: Surfaces.tintColors(for: $0), of: theme.palette)
    }
    for surfaces in variants {
        let chrome = Chrome(Pair(light: surfaces, dark: surfaces))
        // The header's two inks where its name and folder would be, beside its bare background, over a
        // terminal's worth of empty card, all on the surface of a card without the focus.
        let card = Color.clear
            .frame(width: 160, height: 160)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Color.primary.frame(width: 40)
                    chrome.detail.frame(width: 40)
                }
                .frame(height: CardHeader.height)
            }
            .modifier(CardSurface(compact: false, dimmed: true, header: CardHeader.height, chrome: chrome))
            .padding(20)
            .environment(\.colorScheme, dark ? .dark : .light)
        let pixel = try rendered(card)
        let header = pixel(150, 42)
        for (part, ink) in [("name", pixel(40, 42)), ("folder", pixel(80, 42))] {
            #expect(contrast(ink, header) >= (dark ? 5.3 : 4.5),
                    "\(part) \(String(format: "%06X", ink)) on \(String(format: "%06X", header))")
        }
        #expect(pixel(100, 140) != header, "the terminal of a card without the focus should dim")
    }
}

@MainActor
@Test("Through an unfocused card's dim, the faintest text its terminal draws still reads at 3:1",
      arguments: everyTheme)
func dimmedTextReadable(theme: LhunTheme, dark: Bool) throws {
    let plain = Surfaces(theme)
    let variants = [plain] + [Host.mac.id, Host.server.id].map {
        plain.tinted(by: Surfaces.tintColors(for: $0), of: theme.palette)
    }
    for surfaces in variants {
        let chrome = Chrome(Pair(light: surfaces, dark: surfaces))
        // Text in the card's own color is the faintest there is: the floor takes it the whole gap away.
        let faintest = Contrast.readable(surfaces.card, on: surfaces.card, dimmed: true)
        func card(_ terminal: Color) throws -> (Int, Int) -> UInt32 {
            try rendered(
                terminal
                    .frame(width: 160, height: 160)
                    .modifier(CardSurface(compact: false, dimmed: true, header: CardHeader.height, chrome: chrome))
                    .padding(20)
                    .environment(\.colorScheme, dark ? .dark : .light)
            )
        }
        let (text, bare) = try (card(Color(uiColor: Theme.uiColor(faintest))), card(.clear))
        // The dim is the flat wash, so one point in the terminal's middle, clear of the card's rounded
        // corners, reads for all of it.
        let (x, y) = (100, (20 + Int(CardHeader.height) + 180) / 2)
        #expect(contrast(text(x, y), bare(x, y)) >= 3,
                "\(String(format: "%06X", text(x, y))) on \(String(format: "%06X", bare(x, y)))")
    }
}

@Test("In the compact layout the line between two dark cards shows as a hairline as quiet as Apple's dark separators",
      arguments: LhunTheme.list(dark: true))
func darkHairlineShows(theme: LhunTheme) {
    let plain = Surfaces(theme)
    let variants = [plain] + [Host.mac.id, Host.server.id].map {
        plain.tinted(by: Surfaces.tintColors(for: $0), of: theme.palette)
    }
    for surfaces in variants {
        // The line is drawn over a card. Composite it in sRGB, independently of the implementation under test.
        var line: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let ink = Double(surfaces.hairlineInk >> shift & 255)
            let base = Double(surfaces.card >> shift & 255)
            line |= UInt32((ink * surfaces.hairlineOpacity + base * (1 - surfaces.hairlineOpacity)).rounded()) << shift
        }
        // Apple's dark separator, 38383A, is 1.65:1 on a card this dark.
        let ratio = contrast(line, surfaces.card)
        #expect((1.5...1.8).contains(ratio),
                "\(String(format: "%06X", line)) on \(String(format: "%06X", surfaces.card)) is \(ratio):1")
    }
}

/// `view` drawn at a pixel a point, read back as sRGB colors by pixel from its top left.
@MainActor
private func rendered(_ view: some View) throws -> (Int, Int) -> UInt32 {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let row = context.bytesPerRow
    let data = try #require(context.data)
    let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: row * image.height))
    return { x, y in
        let i = y * row + x * 4
        return UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
    }
}

@Test("A host's look reads back as it was saved", arguments: [HostLook.lhun, .tinted, .theme("ember-study"), .theme(LhunTheme.ghosttyID)])
func hostLookSaved(look: HostLook) {
    #expect(HostLook(saved: look.saved) == look)
}
