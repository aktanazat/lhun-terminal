import SwiftUI

/// ⌘K: every action that is not typing into the terminal, in groups with a hairline between: Recent,
/// Sessions, Agents, Commands, Files and Settings. Typing a few of a row's letters in order, or its first
/// word with a typo, keeps the rows that match, best first, the letters that matched in bold
/// (`PaletteRanking`). The arrow keys move through the rows, Tab and Shift-Tab jump between the groups, and
/// Return runs the row.
struct Palette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var list = PaletteList.commands

    /// For the probe: the palette's rows drawn now, which stays at what fits on the card however many
    /// rows there are.
    static var rowsDrawn = 0

    var body: some View {
        let actions = AppActionCatalog(model: model, dark: colorScheme == .dark, openURL: { openURL($0) })
        ZStack {
            if list == .bindings {
                ActionBindingManager(commands: actions.catalog + actions.fontCommands) { list = .commands }
            } else {
                let commands = list == .fonts ? actions.fontCommands : actions.catalog
                PaletteResults(list: list, commands: commands, entries: commands.map(\.entry)) { list = $0 }
                    .id(list)
            }
        }
        .onAppear {
            model.refreshLists()
            model.loadActions()
            model.loadWindows()
        }
    }
}

@MainActor
struct AppActionCatalog {
    let model: AppModel
    let dark: Bool
    var openURL: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    /// Every command, each group's in its order: sessions with the ones that want him on top, sessions
    /// running an agent the same way, then commands, files and settings.
    var catalog: [Command] {
        let (sessions, agents) = sessionCommands
        return (sessions + windowCommands + agents + commands + previewCommands + actionCommands + fileCommands + settingCommands).map { command in
            var command = command
            let custom = ActionBindings.shared.bindings.filter { $0.actionID == command.id && $0.scope == .shortcut }.map(\.title)
            if !custom.isEmpty { command.shortcut = ([command.shortcut].compactMap { $0 } + custom).joined(separator: ", ") }
            return command
        }
    }

    func command(_ id: String) -> Command? {
        if id.hasPrefix("font.") { return fontCommands.first { $0.id == id } }
        if id.hasPrefix("action.") { return actionCommands.first { $0.id == id } }
        if id.hasPrefix("open.") {
            let (sessions, agents) = sessionCommands
            return (sessions + agents).first { $0.id == id }
        }
        if id.hasPrefix("window.") {
            if let command = windowCommands.first(where: { $0.id == id }) { return command }
            guard let ref = model.selection, let index = Int(id.dropFirst("window.".count)), index >= 0 else { return nil }
            return Command(id: id, title: "Window \(index)", group: .sessions) {
                model.selectWindow(index, in: ref)
            }
        }
        if id == "preview" || id.hasPrefix("preview.") { return previewCommands.first { $0.id == id } }
        if let command = commands.first(where: { $0.id == id }) { return command }
        if let command = fileCommands.first(where: { $0.id == id }) { return command }
        return settingCommands.first { $0.id == id }
    }

    /// The fonts the terminal can draw in, the one in use checked.
    var fontCommands: [Command] {
        TerminalFont.allCases.map { font in
            Command(
                id: "font.\(font.rawValue)", title: font.title, detail: font == .xenon ? "with Nerd Font icons" : "",
                group: .settings, isCurrent: font == model.terminalFont
            ) { model.setTerminalFont(font) }
        }
    }

    /// The other sessions, those running a coding agent apart, each list with the sessions that want him
    /// first, then those that finished. Beside its name a session says one thing: what its program reports,
    /// else where it is. Typing still finds it by its host, program and folder.
    private var sessionCommands: (sessions: [Command], agents: [Command]) {
        var sessions: [[Command]] = [[], [], []]
        var agents: [[Command]] = [[], [], []]
        for link in model.links {
            for session in link.sessions {
                let ref = SessionRef(host: link.host.id, name: session.name)
                guard ref != model.selection else { continue }
                let mark = model.attention.mark(ref, open: model.selection)
                let status = model.attention.status(ref, open: model.selection)
                let isAgent = TmuxWatch.isAgent(session.command)
                var command = Command(
                    id: "open.\(link.host.id).\(session.name)", title: session.name,
                    detail: AttentionMark.words(status) ?? model.whereabouts(of: session, on: link.host),
                    group: isAgent ? .agents : .sessions, mark: mark
                ) { model.select(ref) }
                command.keywords = [link.host.name, session.command, session.folder]
                command.spoken = AttentionMark.label(mark, status: status)
                let rank = switch mark {
                case .needsYou: 0
                case .finished: 1
                case .working, nil: 2
                }
                if isAgent { agents[rank].append(command) } else { sessions[rank].append(command) }
            }
        }
        return (sessions.flatMap { $0 }, agents.flatMap { $0 })
    }

    /// The open session's windows, listed with the sessions, the active one checked. "window of" and the
    /// session's name find them; a window says what it runs only when its name does not.
    private var windowCommands: [Command] {
        guard let ref = model.selection else { return [] }
        return (model.windowList.flatMap { $0.session == ref ? $0.windows : nil } ?? []).map { window in
            // Windows often share a name, so each says its number, as tmux's status line does.
            var command = Command(
                id: "window.\(window.index)", title: window.name,
                detail: window.command == window.name ? "window \(window.index)" : "\(window.command) in window \(window.index)",
                group: .sessions, isCurrent: window.isActive
            ) { model.selectWindow(window.index, in: ref) }
            command.keywords = ["window of \(ref.name)"]
            // Window numbers belong to the session open now, so a run of one is not one to remember.
            command.remembered = false
            return command
        }
    }

    /// What he does with the sessions, their windows and the screen.
    private var commands: [Command] {
        var list = [
            Command(id: "palette", title: "Commands…", shortcut: "⌘K") { model.togglePalette() },
            Command(id: "previous-tab", title: "Previous Tab", shortcut: "⇧⌘[") { model.step(-1) },
            Command(id: "next-tab", title: "Next Tab", shortcut: "⇧⌘]") { model.step(1) },
            Command(id: "one-shot-keys", title: "One-Shot Keys") { ActionBindings.shared.startOneShot() },
        ]
        if let link = model.currentLink {
            list.append(Command(id: "new", title: "New Session", detail: "on \(link.host.name)", shortcut: "⌘T") {
                model.newSession(on: link)
            })
        }
        list.append(Command(id: "peek", title: "Show All Sessions", shortcut: "⌘⇧\\") { model.togglePeek() })
        list.append(Command(id: "inbox", title: "Inbox", shortcut: "⌘⇧I") { model.toggleInbox() })
        if model.sidebar.replacesStrip {
            list.append(Command(id: "sidebar", title: model.sidebar.isOn ? "Hide Sidebar" : "Show Sidebar", shortcut: "⌃⌘S") {
                model.toggleSidebar(animated: false)
            })
            let activity = model.sidebar.showingActivity
            list.append(Command(id: "activity", title: activity ? "Clear Activity Filter" : "Filter by Activity", shortcut: "⌘⇧A") {
                model.toggleActivity(animated: false)
            })
        }
        for link in model.links where link !== model.currentLink {
            list.append(Command(id: "host.\(link.host.id)", title: "Switch to \(link.host.name)") { model.switchHost(to: link) })
        }
        if let ref = model.selection {
            list += windowSteps(of: ref)
            list.append(Command(id: "catch-up", title: "Catch Up on This Session") { model.openInbox(catchingUp: true) })
            list.append(Command(id: "rename", title: "Rename Session…") { model.renaming = ref })
            list.append(Command(id: "detach", title: "Detach") { model.detachSelected() })
            if let terminal = model.selectedTerminal, terminal.shared {
                // Another screen has the session open too (SharedSize).
                if case .watch = terminal.sizing {
                    list.append(Command(id: "take-size", title: "Take Size") { terminal.takeSize() })
                } else {
                    list.append(Command(id: "give-back-size", title: "Give Back Size") { terminal.giveBackSize() })
                }
            }
            list.append(Command(id: "split", title: "Split Right", shortcut: "⌘D") { model.split(.right) })
            list.append(Command(id: "split-down", title: "Split Down", shortcut: "⇧⌘D") { model.split(.bottom) })
            if model.isSplit {
                let zoomed = model.zoomed != nil
                list.append(Command(id: "zoom-card", title: zoomed ? "Restore Cards" : "Zoom Card", shortcut: "⇧⌘↩") {
                    model.toggleZoom(ref)
                })
                list.append(Command(id: "other-card", title: "Focus Other Card", shortcut: "⌘[ ⌘]") { model.focusOtherCard() })
                list.append(Command(id: "focus-previous-card", title: "Focus Previous Card", shortcut: "⌘[") { model.focusCard(by: -1) })
                list.append(Command(id: "focus-next-card", title: "Focus Next Card", shortcut: "⌘]") { model.focusCard(by: 1) })
                list.append(Command(id: "balance-cards", title: "Balance Cards", shortcut: "⌃⌥⌘0") { model.balanceCards() })
                list.append(Command(id: "grow-card", title: "Grow Focused Card", shortcut: "⌃⌥⌘=") { model.resizeFocusedSplit(by: 0.05) })
                list.append(Command(id: "shrink-card", title: "Shrink Focused Card", shortcut: "⌃⌥⌘-") { model.resizeFocusedSplit(by: -0.05) })
            }
            list.append(Command(id: "float-card", title: model.isFloating(ref) ? "Tile Card" : "Float Card") { model.toggleFloatingCard(ref) })
            list.append(Command(id: "find-history", title: "Find in History", shortcut: "⌘F") { model.selectedTerminal?.view.findInHistory?() })
            list.append(Command(id: "history.prompt.previous", title: "Previous Prompt") { model.selectedTerminal?.view.stepPrompt?(-1) })
            list.append(Command(id: "history.prompt.next", title: "Next Prompt") { model.selectedTerminal?.view.stepPrompt?(1) })
            list.append(Command(id: "close-session", title: "Close Session", shortcut: "⌘W") { model.kill(ref) })
            list.append(Command(id: "escape", title: "Send Escape", shortcut: "⌘.") { model.sendEscape() })
            list.append(Command(id: "kill", title: "Kill Session…") { model.killing = ref })
            list.append(Command(id: "dictate", title: "Dictate") { model.toggleDictation() })
            list.append(Command(id: "copy-screen", title: "Copy Screen") { model.copyScreen() })
            list.append(Command(id: "share-screen", title: "Share Screen…") { model.shareScreen() })
        }
        if let url = Host.codeURL {
            list.append(Command(id: "code", title: "Open VS Code", detail: "on the Mac") { openURL(url) })
        }
        return list
    }

    private var previewCommands: [Command] {
        guard let link = model.previewLink else { return [] }
        var list: [Command] = []
        for port in model.selectedTerminal?.screenPorts ?? [] {
            list.append(Command(id: "preview.\(port)", title: "Preview localhost:\(port)", detail: "on \(link.host.name)") {
                model.openPreview(port: port, on: link)
            })
        }
        list.append(Command(id: "preview", title: "Preview Port…", detail: "on \(link.host.name)") { model.askingPort = true })
        return list
    }

    /// A new window in the open session, a rename of its active one, and the keys that step through its
    /// windows and move the shown one.
    private func windowSteps(of ref: SessionRef) -> [Command] {
        let list = model.windowList.flatMap { $0.session == ref ? $0.windows : nil } ?? []
        let folder = model.link(for: ref)?.sessions.first { $0.name == ref.name }?.folder ?? ""
        var rows = [
            Command(id: "new-window", title: "New Window", detail: folder.isEmpty ? "" : "in \(folder)") { model.newWindow(in: ref) },
        ]
        if let active = list.first(where: \.isActive) {
            rows.append(Command(id: "rename-window", title: "Rename Window…", detail: active.name) {
                model.renamingWindow = WindowTarget(session: ref, index: active.index, name: active.name)
            })
        }
        let at = list.firstIndex(where: \.isActive)
        let next = at.map { list[($0 + 1) % list.count].name } ?? ""
        let previous = at.map { list[($0 + list.count - 1) % list.count].name } ?? ""
        rows.append(Command(id: "next-window", title: "Next Window", detail: next, shortcut: "⌃⇥") { model.stepWindow(1) })
        rows.append(Command(id: "previous-window", title: "Previous Window", detail: previous, shortcut: "⌃⇧⇥") {
            model.stepWindow(-1)
        })
        rows.append(Command(id: "move-window-left", title: "Move Window Left", shortcut: "⌥⌘[") { model.moveWindow(-1) })
        rows.append(Command(id: "move-window-right", title: "Move Window Right", shortcut: "⌥⌘]") { model.moveWindow(1) })
        return rows
    }

    /// Each host's saved actions, from its ~/.config/lhun/actions.json, each with the host it runs on.
    /// "saved action" is among the words that find them, so typing "actions" lists them all.
    private var actionCommands: [Command] {
        model.links.flatMap { link in
            model.offeredActions(on: link).map { action in
                var command = Command(id: action.actionID(on: link.host.id), title: action.title, detail: "on \(link.host.name)") {
                    model.run(action, on: link)
                }
                command.keywords = ["saved action", action.place.phrase, action.folder ?? ""]
                return command
            }
        }
    }

    /// Paths put in at the cursor, files fetched from the host, and folders to open a session in.
    private var fileCommands: [Command] {
        var list: [Command] = []
        if model.selection != nil {
            list.append(Command(id: "insert-path", title: "Insert Path…", group: .files, shortcut: "⌘P") { model.togglePathPicker() })
            list.append(Command(id: "get-file", title: "Get File…", group: .files, shortcut: "⇧⌘O") { model.togglePathPicker(.getFile) })
        }
        if model.currentLink != nil {
            list.append(Command(id: "go-to-folder", title: "Go to Folder…", group: .files, shortcut: "⇧⌘G") {
                model.togglePathPicker(.goTo)
            })
        }
        return list
    }

    /// Settings he turns on and off here.
    private var settings: [PaletteSetting] {
        [
            PaletteSetting(id: "sounds", title: "Sounds", isOn: model.soundsOn) { model.toggleSounds() },
            PaletteSetting(id: "option-meta", title: "Option as Meta", isOn: model.optionAsMeta) { model.toggleOptionAsMeta() },
            PaletteSetting(id: "caps-escape", title: "Caps Lock as Escape", isOn: model.capsLockAsEscape) {
                model.toggleCapsLockAsEscape()
            },
            PaletteSetting(id: "copy-on-select", title: "Copy on Select", isOn: model.copyOnSelect) { model.toggleCopyOnSelect() },
            PaletteSetting(id: "compact-layout", title: "Compact Layout", isOn: model.compactLayout) { model.toggleCompactLayout() },
        ]
    }

    private var settingCommands: [Command] {
        settings.map { setting in
            Command(id: setting.id, title: setting.title, group: .settings, state: setting.isOn, run: setting.toggle)
        } + [
            Command(id: "layout", title: "Layout", group: .settings, value: model.sidebar.layout.title) { model.switchLayout() },
            Command(id: "font", title: "Font…", group: .settings, value: model.terminalFont.shortTitle, opens: .fonts) {},
            Command(id: "bindings", title: "Keyboard Bindings…", group: .settings, opens: .bindings) {},
            Command(id: "bigger", title: "Bigger Text", group: .settings, shortcut: "⌘=") { model.zoom(by: 1) },
            Command(id: "smaller", title: "Smaller Text", group: .settings, shortcut: "⌘-") { model.zoom(by: -1) },
            Command(id: "actual", title: "Actual Size", group: .settings, shortcut: "⌘0") { model.resetZoom() },
        ] + themeCommands + [
            Command(id: "key", title: "Pair a Mac or Server…", group: .settings) { model.showingKey = true },
        ]
    }

    /// The theme pickers, each with what it shows now, and the appearance, the one chosen checked.
    private var themeCommands: [Command] {
        let store = ThemeStore.shared
        var commands = [
            Command(id: "theme", title: "Theme…", group: .settings, value: store.theme(dark: dark).name) {
                model.openThemePicker(for: nil, dark: dark)
            },
        ]
        for host in Host.all {
            let value = switch store.look(of: host.id, dark: dark) {
            case .lhun: "Lhûn's theme"
            case .tinted: "Tinted"
            case .theme: store.theme(for: host.id, dark: dark).name
            }
            commands.append(Command(id: "theme.\(host.id)", title: "Theme for \(host.name)…", group: .settings, value: value) {
                model.openThemePicker(for: host, dark: dark)
            })
        }
        let appearances: [(ThemeStore.Appearance, title: String)] = [
            (.device, "Match \(UIDevice.current.model)"),
            (.light, "Light"),
            (.dark, "Dark"),
        ]
        for (appearance, title) in appearances {
            commands.append(Command(
                id: "appearance.\(appearance.rawValue)", title: "Appearance: \(title)", group: .settings,
                isCurrent: store.appearance == appearance
            ) { store.setAppearance(appearance) })
        }
        return commands
    }
}

/// The card for one list: ranks its commands as he types and lists them in their groups, a hairline
/// between one group and the next. Only the rows in sight are drawn.
private struct PaletteResults: View {
    @Environment(AppModel.self) private var model
    let list: PaletteList
    let commands: [Command]
    let entries: [PaletteEntry]
    let show: (PaletteList) -> Void
    @State private var query = ""
    @State private var highlighted = 0

    var body: some View {
        let shown = listing(FuzzyQuery(query))
        PaletteCard(
            prompt: list == .fonts ? "Choose a font" : "Type a command or session",
            query: $query,
            fieldID: "palette.query",
            highlightedID: shown.order.indices.contains(highlighted) ? Listing.Line.id(highlighted) : nil,
            onMove: { step in
                guard !shown.order.isEmpty else { return }
                highlighted = (highlighted + step + shown.order.count) % shown.order.count
            },
            onSubmit: { run(shown, at: highlighted) },
            onClose: { model.closePalette() },
            onDeleteEmpty: list == .commands ? nil : { show(.commands) },
            onTab: list == .commands ? { jump($0, firsts: shown.firsts) } : nil
        ) {
            // Keyed by place, so the list can scroll the highlight to a row not drawn yet, and no row ever moves:
            // the lazy stack leaves a row that moved drawn as it stood before.
            ForEach(shown.lines) { line in
                if line.startsGroup {
                    PaletteDivider()
                }
                let command = line.command
                Button {
                    run(shown, at: line.place)
                } label: {
                    Row(
                        command: command, matched: line.read.map { Set(FuzzyMatch.positions($0, in: command.entry.words)) } ?? [],
                        isHighlighted: line.place == highlighted
                    )
                }
                .buttonStyle(.plain)
                .opacity(command.isEnabled ? 1 : 0.45)
                .accessibilityIdentifier("palette.\(command.id)")
                .accessibilityValue(
                    command.spoken ?? command.value
                        ?? (command.isCurrent ? "current" : command.state.map { $0 ? "on" : "off" } ?? "")
                )
            }
        }
        .onAppear { model.probe?.paletteDrawn("open", rows: shown.order.count) }
        .onChange(of: query) {
            highlighted = 0
            model.probe?.paletteDrawn("filter", rows: shown.order.count)
        }
        .onChange(of: highlighted) { model.probe?.paletteDrawn("move", rows: shown.order.count) }
    }

    /// The rows the card lists for what is typed, in their groups.
    private struct Listing {
        /// One row as listed: where it stands in `order`, whether a group after the first starts at it, what was
        /// typed as it matched, and its command.
        struct Line: Identifiable {
            let place: Int
            let startsGroup: Bool
            let read: FuzzyQuery?
            let command: Command
            var id: String { Self.id(place) }

            static func id(_ place: Int) -> String { String(place) }
        }

        /// The commands, and the row that creates a session when there is one.
        var rows: [Command]
        var sections: [PaletteSection]
        /// Every row listed, top to bottom, which the highlight steps through.
        var order: [PaletteHit] { sections.flatMap(\.hits) }
        /// Where in `order` each section starts.
        var firsts: [Int] {
            var start = 0
            return sections.map { section in
                defer { start += section.hits.count }
                return start
            }
        }

        /// Every row listed, top to bottom.
        var lines: [Line] {
            var lines: [Line] = []
            for (at, section) in sections.enumerated() {
                for (offset, hit) in section.hits.enumerated() {
                    lines.append(Line(place: lines.count, startsGroup: at > 0 && offset == 0, read: hit.read, command: rows[hit.index]))
                }
            }
            return lines
        }
    }

    private func listing(_ search: FuzzyQuery) -> Listing {
        // The fonts list is short and has no groups: only the commands list remembers what he ran.
        let uses = list == .commands ? model.paletteUses : PaletteUses()
        var shown = Listing(rows: commands, sections: PaletteRanking.sections(entries, query: search, uses: uses, now: .now))
        guard list == .commands, let create = createRow(shown.sections, search: search) else { return shown }
        // Last among the sessions: Return still runs a better match, and creates when nothing else matched.
        shown.rows.append(create)
        let hit = PaletteHit(index: shown.rows.count - 1, read: nil)
        if let at = shown.sections.firstIndex(where: { $0.group == .sessions }) {
            shown.sections[at].hits.append(hit)
        } else {
            shown.sections.append(PaletteSection(group: .sessions, hits: [hit]))
        }
        return shown
    }

    /// Tab: the first row of the next group, or of the one before for Shift-Tab, round the ends.
    private func jump(_ step: Int, firsts: [Int]) {
        guard !firsts.isEmpty else { return }
        let current = firsts.lastIndex { $0 <= highlighted } ?? 0
        highlighted = firsts[(current + step + firsts.count) % firsts.count]
    }

    private func run(_ shown: Listing, at place: Int) {
        guard shown.order.indices.contains(place) else { return }
        let command = shown.rows[shown.order[place].index]
        guard command.isEnabled else { return }
        if let next = command.opens { return show(next) }
        model.dispatchAction(command, remember: true)
        model.closePalette()
    }

    /// When what is typed names no session, a new session by that name on the current host. tmux takes no
    /// "." or ":" in a name, so such a name is refused on the row. A session counts as named when its own
    /// name holds the letters, not only its host or folder.
    private func createRow(_ sections: [PaletteSection], search: FuzzyQuery) -> Command? {
        guard let link = model.currentLink else { return nil }
        let named = sections.contains { section in
            section.hits.contains { hit in
                let command = commands[hit.index]
                return command.id.hasPrefix("open.") && FuzzyMatch.score(search, command.title) != nil
            }
        }
        guard let name = FilterOrCreate.name(query, sessions: link.sessions.map(\.name), sessionMatched: named) else { return nil }
        let allowed = Tmux.isAllowedName(name)
        var command = Command(
            id: "create", title: "New Session “\(name)”", detail: allowed ? "on \(link.host.name)" : "names can't have . or :",
            group: .sessions, isEnabled: allowed
        ) { model.newSession(named: name, on: link) }
        command.remembered = false
        return command
    }
}

/// A setting he turns on or off from the palette. It is listed with the settings, checked while on.
private struct PaletteSetting {
    let id: String
    let title: String
    let isOn: Bool
    let toggle: @MainActor () -> Void
}

/// What the palette card lists.
enum PaletteList {
    case commands
    case fonts
    case bindings
}

struct Command: Identifiable {
    let id: String
    let title: String
    /// The one plain fact beside the title, when the row has one.
    var detail = ""
    /// The group the command is listed under.
    var group: PaletteGroup = .commands
    var shortcut: String?
    /// What the session wants, for a session row.
    var mark: AttentionBoard.Mark?
    /// What VoiceOver and UI tests read for a session row: its mark, then what the program behind it says.
    var spoken: String?
    /// False for a row that only explains why it cannot run.
    var isEnabled = true
    /// Checked: the window the session shows, the font in use, the appearance chosen.
    var isCurrent = false
    /// On or off, for a setting, checked while on.
    var state: Bool?
    /// What a setting with a choice is set to, shown on the right.
    var value: String?
    /// The list the row turns the card to, in place of running.
    var opens: PaletteList?
    /// Whether running it counts towards Recent and its rank (`PaletteUses`).
    var remembered = true
    /// What else typing finds the row by, not shown: what its one fact leaves out.
    var keywords: [String] = []
    let run: @MainActor () -> Void

    var entry: PaletteEntry {
        PaletteEntry(id: id, group: group, title: title, detail: detail, keywords: keywords.joined(separator: " "))
    }
}

/// A command: its title, its one fact when it has one, then on the right the session's mark, a checkmark,
/// what a setting is set to or the command's shortcut.
private struct Row: View {
    let command: Command
    /// Where the typed letters matched, as UTF-8 offsets into the title, a space, then the detail.
    let matched: Set<Int>
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: Metrics.near) {
            Text(Self.marked(command.title, matched, from: 0, in: .subheadline))
                .foregroundStyle(.primary)
            if !command.detail.isEmpty {
                Text(Self.marked(command.detail, matched, from: command.title.utf8.count + 1, in: .footnote))
                    .foregroundStyle(Theme.detail)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metrics.near)
            if let mark = command.mark {
                AttentionMark(mark: mark)
            }
            if command.isCurrent || command.state == true {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            if let value = command.value {
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
            }
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
            }
        }
        .lineLimit(1)
        .paletteRow(isHighlighted: isHighlighted)
        .onAppear { Palette.rowsDrawn += 1 }
        .onDisappear { Palette.rowsDrawn -= 1 }
    }

    /// `text` in `style`, with the letters at `matched` in its semibold. Offsets in `matched` count UTF-8
    /// bytes and start at `start` for the first letter of `text`.
    private static func marked(_ text: String, _ matched: Set<Int>, from start: Int, in style: Font) -> AttributedString {
        var result = AttributedString()
        var run = ""
        var runIsBold = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.swiftUI.font = runIsBold ? style.weight(.semibold) : style
            result += piece
            run = ""
        }
        var offset = start
        for character in text {
            let isBold = matched.contains(offset)
            if isBold != runIsBold {
                flush()
                runIsBold = isBold
            }
            run.append(character)
            offset += character.utf8.count
        }
        flush()
        return result
    }
}

private extension SavedAction.Place {
    var phrase: String {
        switch self {
        case .here: "in this session"
        case .session: "new session"
        case .window: "new window"
        }
    }
}

extension AppModel {
    /// ⌘K: opens the palette, or closes it.
    func togglePalette() {
        if showingPalette { closePalette() } else { showingPalette = true }
    }

    /// Closes the palette and gives the terminal the keyboard while the palette's field still holds it,
    /// unless something else takes typing: the keyboard then only brings its key row back, where it would
    /// drop as the field leaves and rise again. A command that opened something in its place closed it.
    func closePalette() {
        guard showingPalette else { return }
        showingPalette = false
        takeKeyboardBack()
    }
}
