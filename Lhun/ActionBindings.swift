import Observation
import UIKit

struct ActionKey: Codable, Hashable {
    let input: String
    let modifiers: Int

    init(_ input: String, _ modifiers: UIKeyModifierFlags = []) {
        self.input = switch input {
        case "\r", "\n": "return"
        case "\t": "tab"
        case "\u{1b}": "escape"
        case "\u{8}", "\u{7f}": "delete"
        case UIKeyCommand.inputUpArrow: "up"
        case UIKeyCommand.inputDownArrow: "down"
        case UIKeyCommand.inputLeftArrow: "left"
        case UIKeyCommand.inputRightArrow: "right"
        default: input.lowercased()
        }
        self.modifiers = modifiers.intersection([.command, .control, .alternate, .shift]).rawValue
    }

    var commandInput: String {
        switch input {
        case "return": "\r"
        case "tab": "\t"
        case "escape": UIKeyCommand.inputEscape
        case "delete": "\u{8}"
        case "up": UIKeyCommand.inputUpArrow
        case "down": UIKeyCommand.inputDownArrow
        case "left": UIKeyCommand.inputLeftArrow
        case "right": UIKeyCommand.inputRightArrow
        default: input
        }
    }

    @MainActor
    init?(_ key: UIKey) {
        let input: String
        switch key.keyCode {
        case .keyboardLeftControl, .keyboardRightControl, .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI:
            return nil
        case .keyboardEscape: input = "escape"
        case .keyboardReturnOrEnter, .keypadEnter: input = "return"
        case .keyboardTab: input = "tab"
        case .keyboardDeleteOrBackspace: input = "delete"
        case .keyboardUpArrow: input = "up"
        case .keyboardDownArrow: input = "down"
        case .keyboardLeftArrow: input = "left"
        case .keyboardRightArrow: input = "right"
        default:
            input = key.charactersIgnoringModifiers
            guard !input.isEmpty else { return nil }
        }
        self.init(input, key.modifierFlags)
    }

    var hasCommandModifier: Bool {
        !UIKeyModifierFlags(rawValue: modifiers).isDisjoint(with: [.command, .control, .alternate])
    }

    var title: String {
        let flags = UIKeyModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.alternate) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        let key = switch input {
        case "escape": "Esc"
        case "return": "↩"
        case "tab": "⇥"
        case "delete": "⌫"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case " ": "Space"
        default: input.uppercased()
        }
        return result + key
    }
}

struct ActionBinding: Codable, Identifiable, Equatable {
    enum Scope: String, Codable, CaseIterable {
        case shortcut
        case oneShot

        var title: String { self == .shortcut ? "Shortcut" : "One-Shot" }
    }

    var id = UUID()
    let actionID: String
    let actionTitle: String
    let keys: [ActionKey]
    let scope: Scope

    var title: String { keys.map(\.title).joined(separator: " ") }
}

@MainActor @Observable
final class ActionBindings {
    static let shared = ActionBindings()
    private static let defaultsKey = "actionBindings"

    private(set) var bindings: [ActionBinding]
    private(set) var prefix: ActionKey?
    private(set) var oneShot = false
    private var candidates: [ActionBinding] = []

    init() {
        if let data = LhunDefaults.shared.data(forKey: Self.defaultsKey),
           let saved = try? PropertyListDecoder().decode([ActionBinding].self, from: data) {
            bindings = saved
        } else {
            bindings = []
        }
    }

    var isPending: Bool { prefix != nil || oneShot }

    var pendingTitle: String {
        if let prefix { return "\(prefix.title) …" }
        return "One-Shot Keys"
    }

    var pendingChoices: String {
        let offered = prefix == nil ? bindings.filter { $0.scope == .oneShot } : candidates
        return offered.map { binding in
            let keys = prefix == nil ? binding.title : binding.keys.last?.title ?? ""
            return "\(keys): \(binding.actionTitle)"
        }.joined(separator: " · ")
    }

    func startOneShot() {
        cancel()
        oneShot = true
    }

    func cancel() {
        prefix = nil
        candidates = []
        oneShot = false
    }

    enum Result {
        case pass
        case consumed
        case action(String)
    }

    func receive(_ key: ActionKey) -> Result {
        if isPending, key == ActionKey("escape") {
            cancel()
            return .consumed
        }
        if let action = Self.builtIns.first(where: { $0.key == key }) {
            cancel()
            return .action(action.id)
        }
        if prefix != nil {
            let match = candidates.first { $0.keys.last == key }
            cancel()
            if let match { return .action(match.actionID) }
            return receive(key)
        }
        guard oneShot || key.hasCommandModifier else { return .pass }
        let scope: ActionBinding.Scope = oneShot ? .oneShot : .shortcut
        for binding in bindings where binding.scope == scope && binding.keys.first == key {
            if binding.keys.count == 1 {
                cancel()
                return .action(binding.actionID)
            }
            candidates.append(binding)
        }
        guard !candidates.isEmpty else {
            if oneShot { cancel() }
            return .pass
        }
        prefix = key
        return .consumed
    }

    func problem(for keys: [ActionKey], scope: ActionBinding.Scope, actionID: String) -> String? {
        guard (1...2).contains(keys.count), let first = keys.first else { return "Press a key." }
        if keys.contains(ActionKey("escape")) { return "Escape cancels a sequence." }
        if scope == .shortcut, !first.hasCommandModifier { return "Hold Command, Control, or Option with the first key." }
        if let reserved = keys.first(where: { Self.reserved.contains($0) }) { return "\(reserved.title) is a built-in shortcut." }
        for binding in bindings where binding.scope == scope && binding.actionID != actionID {
            if binding.keys.starts(with: keys) || keys.starts(with: binding.keys) {
                return "Already bound to \(binding.actionTitle)."
            }
        }
        return nil
    }

    @discardableResult
    func save(actionID: String, title: String, keys: [ActionKey], scope: ActionBinding.Scope) -> String? {
        if let problem = problem(for: keys, scope: scope, actionID: actionID) { return problem }
        let updated = bindings.filter { $0.actionID != actionID || $0.scope != scope }
            + [ActionBinding(actionID: actionID, actionTitle: title, keys: keys, scope: scope)]
        return persist(updated)
    }

    @discardableResult
    func remove(actionID: String, scope: ActionBinding.Scope) -> String? {
        persist(bindings.filter { $0.actionID != actionID || $0.scope != scope })
    }

    private func persist(_ updated: [ActionBinding]) -> String? {
        do {
            let data = try PropertyListEncoder().encode(updated)
            LhunDefaults.shared.set(data, forKey: Self.defaultsKey)
            bindings = updated
            cancel()
            return nil
        } catch {
            return "The binding couldn't be saved. Try again."
        }
    }

    struct BuiltIn {
        let id: String
        let key: ActionKey
    }

    static let builtIns: [BuiltIn] = [
        BuiltIn(id: "new", key: ActionKey("t", .command)),
        BuiltIn(id: "palette", key: ActionKey("k", .command)),
        BuiltIn(id: "insert-path", key: ActionKey("p", .command)),
        BuiltIn(id: "get-file", key: ActionKey("o", [.command, .shift])),
        BuiltIn(id: "go-to-folder", key: ActionKey("g", [.command, .shift])),
        BuiltIn(id: "previous-tab", key: ActionKey("[", [.command, .shift])),
        BuiltIn(id: "next-tab", key: ActionKey("]", [.command, .shift])),
        BuiltIn(id: "peek", key: ActionKey("\\", [.command, .shift])),
        BuiltIn(id: "inbox", key: ActionKey("i", [.command, .shift])),
        BuiltIn(id: "sidebar", key: ActionKey("s", [.command, .control])),
        BuiltIn(id: "activity", key: ActionKey("a", [.command, .shift])),
        BuiltIn(id: "split", key: ActionKey("d", .command)),
        BuiltIn(id: "split-down", key: ActionKey("d", [.command, .shift])),
        BuiltIn(id: "focus-previous-card", key: ActionKey("[", .command)),
        BuiltIn(id: "focus-next-card", key: ActionKey("]", .command)),
        BuiltIn(id: "zoom-card", key: ActionKey("return", [.command, .shift])),
        BuiltIn(id: "move-window-left", key: ActionKey("[", [.command, .alternate])),
        BuiltIn(id: "move-window-right", key: ActionKey("]", [.command, .alternate])),
        BuiltIn(id: "next-window", key: ActionKey("tab", .control)),
        BuiltIn(id: "previous-window", key: ActionKey("tab", [.control, .shift])),
        BuiltIn(id: "close-session", key: ActionKey("w", .command)),
        BuiltIn(id: "escape", key: ActionKey(".", .command)),
        BuiltIn(id: "bigger", key: ActionKey("=", .command)),
        BuiltIn(id: "smaller", key: ActionKey("-", .command)),
        BuiltIn(id: "actual", key: ActionKey("0", .command)),
        BuiltIn(id: "find-history", key: ActionKey("f", .command)),
        BuiltIn(id: "balance-cards", key: ActionKey("0", [.control, .alternate, .command])),
        BuiltIn(id: "grow-card", key: ActionKey("=", [.control, .alternate, .command])),
        BuiltIn(id: "shrink-card", key: ActionKey("-", [.control, .alternate, .command])),
    ] + (1...9).map { BuiltIn(id: "tab.\($0)", key: ActionKey(String($0), .command)) }

    static let reserved = Set(builtIns.map(\.key) + [
        ActionKey("c", .command), ActionKey("v", .command), ActionKey("x", .command),
        ActionKey("a", .command), ActionKey("delete", .command),
    ])
}
