import CryptoKit
import Foundation

/// The Mac's Ghostty theme, read over the SSH link when the theme picker opens, never before, and a Ghostty
/// theme file picked on this device (ThemeStore.swift). Ghostty's config names a theme, one for both
/// appearances or `light:A,dark:B`; the theme's file holds its colors, and colors the config sets itself go
/// over the file's.
enum GhosttyTheme {
    /// The themes the config names.
    struct Names: Equatable, Sendable {
        let light: String
        let dark: String
    }

    /// What one read found: the names, and each appearance's theme where its file was found.
    struct Read: Sendable {
        let names: Names
        let themes: Pair<LhunTheme?>
    }

    /// Reads the config, then the theme files it names: two commands over the link.
    @MainActor
    static func read(over link: HostLink) async throws -> Read? {
        let config = try await link.run(configCommand, timeout: .seconds(10))
        guard let names = Self.names(in: config) else { return nil }
        let wanted = names.light == names.dark ? [names.light] : [names.light, names.dark]
        let found = Self.files(in: try await link.run(themesCommand(wanted), timeout: .seconds(10)))
        func named(_ name: String, dark: Bool) -> LhunTheme? {
            found[name].map { Self.theme(named: name, file: $0, config: config, dark: dark) }
        }
        return Read(names: names, themes: Pair(light: named(names.light, dark: false), dark: named(names.dark, dark: true)))
    }

    /// Prints the config files Ghostty loads, in its order, so what a later one sets wins: the XDG
    /// folder's, then the macOS app folder's. Launched with `-ghosttyConfig <path>`, a check reads that
    /// one file on the Mac instead.
    static var configCommand: String {
        if let path = LhunDefaults.shared.string(forKey: "ghosttyConfig") {
            return "cat \(Tmux.quote(path)); true"
        }
        return #"c="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"; a="$HOME/Library/Application Support/com.mitchellh.ghostty"; for f in "$c/config" "$c/config.ghostty" "$a/config" "$a/config.ghostty"; do [ -f "$f" ] && cat "$f" && echo; done; true"#
    }

    /// Prints each theme's file after a line holding the record separator and its name, from the
    /// user's themes folder first and then the themes Ghostty ships. A name that is a path is read as
    /// it is.
    static func themesCommand(_ names: [String]) -> String {
        let list = names.map(Tmux.quote).joined(separator: " ")
        return #"t="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/themes"; r=/Applications/Ghostty.app/Contents/Resources/ghostty/themes; for n in \#(list); do printf '\036%s\n' "$n"; case "$n" in /*) f="$n";; *) f="$t/$n"; [ -f "$f" ] || f="$r/$n";; esac; [ -f "$f" ] && cat "$f"; echo; done; true"#
    }

    /// The theme files in the themes command's output, by name. A theme whose file was not found is
    /// left out.
    static func files(in output: String) -> [String: String] {
        var files: [String: String] = [:]
        for section in output.split(separator: "\u{1E}") {
            let name = section.prefix { $0 != "\n" }
            let file = section.dropFirst(name.count + 1)
            if !file.allSatisfy(\.isWhitespace) { files[String(name)] = String(file) }
        }
        return files
    }

    /// The theme the configs name, from their text one after another in load order. The last `theme`
    /// line wins, and an empty one clears it. A `light:` and `dark:` pair needs both.
    static func names(in config: String) -> Names? {
        guard let value = settings(in: config).last(where: { $0.key == "theme" })?.value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.contains(where: { $0.hasPrefix("light:") || $0.hasPrefix("dark:") }) else {
            return Names(light: value, dark: value)
        }
        var light: String?
        var dark: String?
        for part in parts {
            if part.hasPrefix("light:") {
                light = part.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if part.hasPrefix("dark:") {
                dark = part.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let light, let dark, !light.isEmpty, !dark.isEmpty else { return nil }
        return Names(light: light, dark: dark)
    }

    /// The id a theme imported from a file is saved under: a hash of the file's text, so importing the same
    /// file twice is one theme, apart from Lhûn's own ids and the Mac's Ghostty theme's.
    static func importedID(_ file: String) -> String {
        let digest = SHA256.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
        return "import:" + String(digest.prefix(12))
    }

    /// A Lhûn theme from a Ghostty theme file picked on this device, in the appearance its background puts
    /// it in. Nil when the file sets no readable background, so a file that is not a theme is refused
    /// rather than read as Mies.
    static func imported(named name: String, file: String) -> LhunTheme? {
        let entries = settings(in: file)
        func last(_ key: String) -> UInt32? {
            entries.last { $0.key == key }.flatMap { color($0.value) }
        }
        guard let background = last("background") else { return nil }
        return theme(named: name, file: file, config: "", dark: Oklab(rgb: background).l <= 0.5, id: importedID(file))
    }

    /// A Lhûn theme from a Ghostty theme file, with the config's own colors over the file's. What
    /// neither sets comes from Mies in the same appearance, and a color Lhûn can't read, such as an
    /// X11 name, counts as unset. `id` is what the theme is saved under.
    static func theme(named name: String, file: String, config: String, dark: Bool, id: String = LhunTheme.ghosttyID) -> LhunTheme {
        let mies = LhunTheme.mies(dark: dark).palette
        var background: UInt32?
        var foreground: UInt32?
        var caret: UInt32?
        var selection: UInt32?
        var ansi = mies.ansi
        for (key, value) in settings(in: file) + settings(in: config) {
            switch key {
            case "background": background = color(value) ?? background
            case "foreground": foreground = color(value) ?? foreground
            case "cursor-color": caret = color(value) ?? caret
            case "selection-background": selection = color(value) ?? selection
            case "palette":
                let entry = value.split(separator: "=", maxSplits: 1)
                guard entry.count == 2, let index = Int(entry[0].trimmingCharacters(in: .whitespaces)), ansi.indices.contains(index),
                      let color = color(String(entry[1]))
                else { continue }
                ansi[index] = color
            default:
                continue
            }
        }
        return LhunTheme(
            id: id, name: name,
            palette: Theme.Palette(
                background: background ?? mies.background,
                foreground: foreground ?? mies.foreground,
                caret: caret ?? foreground ?? mies.caret,
                selection: selection ?? mies.selection,
                ansi: ansi
            )
        )
    }

    /// `key = value` lines, with comments and blank lines left out and a quoted value unquoted.
    private static func settings(in text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return (key, value)
        }
    }

    /// `#RRGGBB` or `RRGGBB`.
    private static func color(_ text: String) -> UInt32? {
        let hex = text.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(hex, radix: 16)
    }
}
