import Foundation
import OSLog
import SwiftTerm

/// A terminal's screen kept on this device as the bytes that draw it again: its text, colors and styles
/// row by row. Lhûn keeps the open cards' screens as it leaves the screen, and a cold launch shows each
/// one while it signs in again and tmux redraws (`TerminalModel.show`). The bytes draw on the alternate
/// screen, where tmux draws, so the blank main screen comes back when tmux leaves; and with the cursor
/// hidden, so the old prompt does not read as live while keys still go nowhere.
struct SavedScreen: Codable, Equatable, Sendable {
    let cols: Int
    let rows: Int
    /// The grid was another screen's, which the card showed smaller to fit (`TerminalModel.Sizing.watch`).
    let watched: Bool
    let bytes: Data

    init(of terminal: Terminal, watched: Bool) {
        cols = terminal.cols
        rows = terminal.rows
        self.watched = watched
        var out = Array("\u{1B}[?1049h\u{1B}[0m\u{1B}[H\u{1B}[2J".utf8)
        var current: Attribute?
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let cells = (0..<min(line.count, terminal.cols)).map { line[$0] }
            guard let last = cells.lastIndex(where: { !Self.erased($0, in: terminal) }) else { continue }
            out += Array("\u{1B}[\(row + 1);1H".utf8)
            for cell in cells[...last] where cell.width > 0 {
                if cell.attribute != current {
                    out += Array(Self.sgr(cell.attribute).utf8)
                    current = cell.attribute
                }
                let character = terminal.getCharacter(for: cell)
                out += Array(String(character == "\0" ? " " : character).utf8)
            }
        }
        let cursor = terminal.getCursorLocation()
        out += Array("\u{1B}[0m\u{1B}[\(cursor.y + 1);\(cursor.x + 1)H\u{1B}[?25l".utf8)
        bytes = Data(out)
    }

    /// A cell that shows only the default background, as an erased one does, which the clear before the
    /// rows already draws.
    private static func erased(_ cell: CharData, in terminal: Terminal) -> Bool {
        let character = terminal.getCharacter(for: cell)
        let style = cell.attribute.style
        let defaultBackground = switch cell.attribute.bg {
        case .defaultColor, .defaultInvertedColor: true
        case .ansi256, .trueColor: false
        }
        return (character == "\0" || character == " ") && defaultBackground
            && style.isDisjoint(with: [.inverse, .underline, .crossedOut])
    }

    /// The whole of an attribute as one SGR sequence, from a reset, so it never depends on the one before.
    private static func sgr(_ attribute: Attribute) -> String {
        let style = attribute.style
        var codes = ["0"]
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) {
            codes.append(attribute.underlineStyle == .none ? "4" : "4:\(attribute.underlineStyle.rawValue)")
        }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes += color(attribute.fg, normal: 30, bright: 90, extended: 38)
        codes += color(attribute.bg, normal: 40, bright: 100, extended: 48)
        if let underline = attribute.underlineColor { codes += color(underline, normal: nil, bright: nil, extended: 58) }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

    /// One color's codes. The first 16 palette colors take their short codes where the slot has them.
    private static func color(_ color: Attribute.Color, normal: Int?, bright: Int?, extended: Int) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return []
        case .ansi256(let code):
            if code < 8, let normal { return ["\(normal + Int(code))"] }
            if code < 16, let bright { return ["\(bright + Int(code) - 8)"] }
            return ["\(extended)", "5", "\(code)"]
        case .trueColor(let red, let green, let blue):
            return ["\(extended)", "2", "\(red)", "\(green)", "\(blue)"]
        }
    }
}

/// The open cards' screens as Lhûn last left them, in the app's caches, by session.
enum SavedScreens {
    private static let file = URL.cachesDirectory.appending(path: "screens.plist")
    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "screens")

    static func load() -> [SessionRef: SavedScreen] {
        guard FileManager.default.fileExists(atPath: file.path()) else { return [:] }
        do {
            let stored = try PropertyListDecoder().decode([String: SavedScreen].self, from: Data(contentsOf: file))
            return Dictionary(uniqueKeysWithValues: stored.compactMap { line, screen in SessionRef(line: line).map { ($0, screen) } })
        } catch {
            log.error("The saved screens can't be read: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Replaces every saved screen with these. Terminal screens can hold anything, so the file is readable
    /// only while the device is unlocked.
    static func save(_ screens: [SessionRef: SavedScreen]) {
        do {
            let stored = Dictionary(uniqueKeysWithValues: screens.map { ($0.key.line, $0.value) })
            try PropertyListEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            log.error("The screens can't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
