import SwiftUI
import UIKit

/// The theme choices: the appearance, Lhûn's theme for light and for dark, how each host looks, the Mac's
/// Ghostty theme as it was last chosen, and the themes imported from Ghostty theme files. Everything that
/// draws asks here, so a choice, or the theme picker's highlight moving, recolors the whole app at once.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()

    enum Appearance: String, CaseIterable, Sendable {
        case device = "match"
        case light
        case dark

        var style: UIUserInterfaceStyle {
            switch self {
            case .device: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// What the picker's highlight shows before it is kept: a look for Lhûn's theme (no host) or for one
    /// host, in one appearance. `theme` is the theme the look names, so a theme not saved yet, such as
    /// the Mac's Ghostty theme as just read, can show.
    struct Preview: Equatable {
        let host: String?
        let dark: Bool
        let look: HostLook
        let theme: LhunTheme?
    }

    private(set) var appearance: Appearance
    /// Lhûn's theme for each appearance, by id.
    private(set) var chosen: Pair<String>
    private(set) var looks: [String: Pair<HostLook>]
    /// The Mac's Ghostty theme for each appearance, as it was when last chosen or read.
    private(set) var ghostty: Pair<LhunTheme?>
    /// The themes imported from Ghostty theme files, each appearance's own, kept on this device: they need
    /// neither the file they came from nor the Mac to show.
    private(set) var imported: [LhunTheme] = []
    private(set) var preview: Preview?
    /// The host whose sessions the strip shows. The wash, the pills and the palette take its look.
    var chromeHost = Host.mac.id {
        didSet {
            if chromes[chromeHost] == nil { rebuild() }
        }
    }
    /// Each host's surfaces as SwiftUI colors, made again when a choice changes.
    private(set) var chromes: [String: Chrome] = [:]

    @ObservationIgnored private let standard = Chrome(Pair(light: Surfaces(.mies(dark: false)), dark: Surfaces(.mies(dark: true))))

    private enum Defaults {
        static let appearance = "appearance"
        static func theme(dark: Bool) -> String { dark ? "themeDark" : "themeLight" }
        static func look(_ host: String, dark: Bool) -> String { "hostTheme.\(host).\(dark ? "dark" : "light")" }
        static func ghostty(dark: Bool) -> String { dark ? "ghosttyDark" : "ghosttyLight" }
    }

    private init() {
        // Each of these also reads a launch argument, such as `-themeDark ember-study`.
        let defaults = LhunDefaults.shared
        appearance = defaults.string(forKey: Defaults.appearance).flatMap(Appearance.init) ?? .device
        chosen = Pair(
            light: defaults.string(forKey: Defaults.theme(dark: false)) ?? "mies",
            dark: defaults.string(forKey: Defaults.theme(dark: true)) ?? "mies"
        )
        var looks: [String: Pair<HostLook>] = [:]
        for host in Host.all {
            func look(dark: Bool) -> HostLook {
                defaults.string(forKey: Defaults.look(host.id, dark: dark)).flatMap(HostLook.init(saved:)) ?? .standard(for: host.id)
            }
            looks[host.id] = Pair(light: look(dark: false), dark: look(dark: true))
        }
        self.looks = looks
        func saved(dark: Bool) -> LhunTheme? {
            defaults.data(forKey: Defaults.ghostty(dark: dark)).flatMap { try? JSONDecoder().decode(LhunTheme.self, from: $0) }
        }
        ghostty = Pair(light: saved(dark: false), dark: saved(dark: true))
        imported = Self.loadImported()
        rebuild()
    }

    // MARK: What shows

    /// Lhûn's theme for one appearance, the picker's highlight included.
    func theme(dark: Bool) -> LhunTheme {
        if let preview, preview.host == nil, preview.dark == dark, let theme = preview.theme { return theme }
        return theme(id: chosen[dark: dark], dark: dark) ?? .mies(dark: dark)
    }

    /// A theme by its id: one of Lhûn's own, the Mac's Ghostty theme as saved, or an imported one. An
    /// imported theme answers only for the appearance its background puts it in.
    func theme(id: String, dark: Bool) -> LhunTheme? {
        if id == LhunTheme.ghosttyID { return ghostty[dark: dark] }
        if let theme = imported.first(where: { $0.id == id }) { return theme.palette.isLight == dark ? nil : theme }
        return LhunTheme.named(id, dark: dark)
    }

    /// How a host looks in one appearance, the picker's highlight included.
    func look(of host: String, dark: Bool) -> HostLook {
        if let preview, preview.host == host, preview.dark == dark { return preview.look }
        return looks[host]?[dark: dark] ?? .standard(for: host)
    }

    /// The theme a host's terminal shows.
    func theme(for host: String, dark: Bool) -> LhunTheme {
        guard case .theme(let id) = look(of: host, dark: dark) else { return theme(dark: dark) }
        if let preview, preview.host == host, preview.dark == dark, let theme = preview.theme { return theme }
        return theme(id: id, dark: dark) ?? theme(dark: dark)
    }

    func palette(for host: String, dark: Bool) -> Theme.Palette {
        theme(for: host, dark: dark).palette
    }

    func surfaces(for host: String, dark: Bool) -> Surfaces {
        let theme = theme(for: host, dark: dark)
        let surfaces = Surfaces(theme)
        guard look(of: host, dark: dark) == .tinted else { return surfaces }
        return surfaces.tinted(by: Surfaces.tintColors(for: host), of: theme.palette)
    }

    /// The colors the strip, the palette and the overlays are drawn in: the strip host's, or while the
    /// picker tries a look on another host, that host's.
    var chrome: Chrome {
        chromes[preview?.host ?? chromeHost] ?? standard
    }

    /// A host's colors, for what shows its sessions apart from the strip's.
    func chrome(for host: String) -> Chrome {
        chromes[host] ?? standard
    }

    // MARK: Choosing

    func setAppearance(_ appearance: Appearance) {
        self.appearance = appearance
        LhunDefaults.shared.set(appearance.rawValue, forKey: Defaults.appearance)
    }

    func setPreview(_ preview: Preview?) {
        guard preview != self.preview else { return }
        self.preview = preview
        rebuild()
    }

    /// Saves a picked theme before changing the selected look; a write failure leaves both unchanged.
    func keep(_ preview: Preview, adopting theme: LhunTheme? = nil) throws {
        let defaults = LhunDefaults.shared
        if let theme, case .theme(let id) = preview.look, id == theme.id {
            var next = imported
            if let index = next.firstIndex(where: { $0.id == theme.id }) {
                next[index] = theme
            } else {
                next.append(theme)
            }
            try saveImported(next)
            imported = next
        }
        if case .theme(let id) = preview.look, id == LhunTheme.ghosttyID, let theme = preview.theme {
            ghostty[dark: preview.dark] = theme
            defaults.set(try? JSONEncoder().encode(theme), forKey: Defaults.ghostty(dark: preview.dark))
        }
        if let host = preview.host {
            looks[host, default: Pair(light: .standard(for: host), dark: .standard(for: host))][dark: preview.dark] = preview.look
            defaults.set(preview.look.saved, forKey: Defaults.look(host, dark: preview.dark))
        } else if case .theme(let id) = preview.look {
            chosen[dark: preview.dark] = id
            defaults.set(id, forKey: Defaults.theme(dark: preview.dark))
        }
        self.preview = nil
        rebuild()
    }

    /// A fresh read of the Mac's Ghostty theme takes the place of the saved one wherever it is in use,
    /// so a change made in Ghostty shows the next time the picker opens. One that is now the other
    /// appearance's leaves the saved one as it was.
    func refreshGhostty(_ theme: LhunTheme, dark: Bool) {
        let inUse = chosen[dark: dark] == LhunTheme.ghosttyID
            || looks.values.contains { $0[dark: dark] == .theme(LhunTheme.ghosttyID) }
        guard inUse, theme.palette.isLight != dark, ghostty[dark: dark] != theme else { return }
        ghostty[dark: dark] = theme
        LhunDefaults.shared.set(try? JSONEncoder().encode(theme), forKey: Defaults.ghostty(dark: dark))
        rebuild()
    }

    // MARK: Importing

    /// Why a file picked on this device did not become a theme.
    enum ImportFailure: LocalizedError {
        case unreadable
        case tooLarge
        case notATheme

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file can't be read."
            case .tooLarge: "That file is too big for a theme."
            case .notATheme: "That file has no Ghostty theme colors."
            }
        }
    }

    /// The largest theme file Lhûn reads: a theme is a page of colors.
    static let importLimit = 256 * 1024

    /// A theme from a Ghostty theme file picked on this device, not yet kept. Its id comes from the file's
    /// text, so the same file imported twice is one theme, and its name is the file's, changed only as far
    /// as it takes to tell it from the themes listed beside it.
    func theme(fromFile url: URL) throws -> LhunTheme {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A file picked in Files can be any size; a theme is a page, so a big one is refused before it is read.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.importLimit {
            throw ImportFailure.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw ImportFailure.unreadable }
        guard data.count <= Self.importLimit else { throw ImportFailure.tooLarge }
        guard let file = String(data: data, encoding: .utf8) else { throw ImportFailure.unreadable }
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
        guard let theme = GhosttyTheme.imported(named: base.isEmpty ? "Imported Theme" : base, file: file) else {
            throw ImportFailure.notATheme
        }
        return LhunTheme(id: theme.id, name: unique(theme.name, for: theme.id), palette: theme.palette, raised: theme.raised)
    }

    /// `name`, or the first of "name 2", "name 3"… that no theme listed beside it has, so two files of one
    /// name read apart in the picker. A theme imported again keeps the name its id already has a place for.
    private func unique(_ name: String, for id: String) -> String {
        let taken = Set(
            (LhunTheme.list(dark: false) + LhunTheme.list(dark: true)).map(\.name)
                + imported.filter { $0.id != id }.map(\.name)
        )
        guard taken.contains(name) else { return name }
        var count = 2
        while taken.contains("\(name) \(count)") { count += 1 }
        return "\(name) \(count)"
    }

    /// Where the imported themes live: the app's own folder, so they are there on the next launch.
    private static var importedFile: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedThemes.json", directoryHint: .notDirectory)
    }

    private static func loadImported() -> [LhunTheme] {
        guard let data = try? Data(contentsOf: importedFile),
              let themes = try? JSONDecoder().decode([LhunTheme].self, from: data)
        else { return [] }
        return themes
    }

    private func saveImported(_ themes: [LhunTheme]) throws {
        try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(themes).write(to: Self.importedFile, options: [.atomic, .completeFileProtection])
    }

    /// A host's colors are made again only when they changed, so views showing the others keep theirs.
    private func rebuild() {
        var chromes: [String: Chrome] = [:]
        for host in Set(Host.all.map(\.id) + [chromeHost]) {
            let surfaces = Pair(light: surfaces(for: host, dark: false), dark: surfaces(for: host, dark: true))
            if let kept = self.chromes[host], kept.surfaces == surfaces {
                chromes[host] = kept
            } else {
                chromes[host] = Chrome(surfaces)
            }
        }
        self.chromes = chromes
    }

    // MARK: Probe

    /// What is chosen and what shows, with the strip host's colors in the appearance on screen.
    var probe: [String: Any] {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let dark = window?.traitCollection.userInterfaceStyle == .dark
        let host = preview?.host ?? chromeHost
        let surfaces = surfaces(for: host, dark: dark)
        func hex(_ value: UInt32) -> String { String(format: "%06X", value) }
        return [
            "appearance": appearance.rawValue,
            "style": dark ? "dark" : "light",
            "light": chosen.light,
            "dark": chosen.dark,
            "looks": looks.mapValues { "\($0.light.saved) \($0.dark.saved)" },
            "preview": preview.map { $0.theme?.name ?? $0.look.saved } ?? "",
            "host": host,
            "shown": theme(for: host, dark: dark).name,
            "wash": hex(surfaces.wash),
            "card": hex(surfaces.card),
            "pill": hex(surfaces.pillInk),
            "ghostty": [ghostty.light?.name ?? "", ghostty.dark?.name ?? ""],
            "imported": imported.map(\.name),
        ]
    }
}

/// One host's surfaces as SwiftUI colors, each following the light or dark appearance by itself.
struct Chrome {
    let surfaces: Pair<Surfaces>
    /// The flat wash everything sits on.
    let wash: SwiftUI.Color
    /// The terminal card, in the terminal's own background.
    let card: SwiftUI.Color
    /// The open session's pill and the palette, lifted off the wash.
    let raised: SwiftUI.Color
    /// Pills that are not open, and the highlighted palette row.
    let pill: SwiftUI.Color
    let hairline: SwiftUI.Color
    /// Opaque text for small descriptions, readable on every surface.
    let detail: SwiftUI.Color

    init(_ surfaces: Pair<Surfaces>) {
        self.surfaces = surfaces
        func color(_ value: (Surfaces) -> UInt32, opacity: (Surfaces) -> Double = { _ in 1 }) -> SwiftUI.Color {
            let light = (value(surfaces.light), opacity(surfaces.light))
            let dark = (value(surfaces.dark), opacity(surfaces.dark))
            return SwiftUI.Color(UIColor { traits in
                let (hex, alpha) = traits.userInterfaceStyle == .dark ? dark : light
                return Theme.uiColor(hex).withAlphaComponent(alpha)
            })
        }
        wash = color(\.wash)
        card = color(\.card)
        raised = color(\.raised)
        pill = color(\.pillInk, opacity: \.pillOpacity)
        hairline = color(\.hairlineInk, opacity: \.hairlineOpacity)
        detail = color(\.detail)
    }
}

/// Puts the chosen appearance on the window, so the app, its sheets and alerts and the keyboard all
/// follow it. "Match iPad" leaves the system's.
struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> Setter {
        let setter = Setter()
        setter.isUserInteractionEnabled = false
        return setter
    }

    func updateUIView(_ setter: Setter, context: Context) {
        setter.style = style
    }

    final class Setter: UIView {
        var style = UIUserInterfaceStyle.unspecified {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
