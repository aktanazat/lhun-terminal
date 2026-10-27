import Network
import NIOCore
import NIOSSH
import Observation
import SwiftUI
import UIKit

/// A tmux session on one of the hosts.
struct SessionRef: Codable, Hashable, Sendable {
    let host: String
    let name: String
}

extension SessionRef {
    /// "host<tab>name": how the open cards are saved, and what a dragged session pill carries.
    var line: String { "\(host)\t\(name)" }

    init?(line: some StringProtocol) {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(host: String(parts[0]), name: String(parts[1]))
    }
}

/// Clipboard text held back until he says to type it (`AppModel.paste`).
struct PendingPaste: Equatable {
    let ref: SessionRef
    let text: String
}

/// Everything the app shows: the hosts and their sessions, which host the strip shows, which sessions
/// are attached, and which are on screen.
@MainActor @Observable
final class AppModel {
    private(set) var links: [HostLink]
    let key: DeviceKey?
    /// Set when this device could not make or load its key, which leaves Lhûn unable to sign in anywhere.
    let keyProblem: String?
    /// Neither host has answered for three rounds in a row on a working network: Tailscale on this device
    /// has stopped carrying traffic while it still shows connected, which turning it off and on clears.
    private(set) var tailscaleStalled = false
    private var workspaces = WorkspaceStore()
    var selection: SessionRef? { workspaces.selection }
    var panes: [SessionRef] { workspaces.panes }
    /// Each pane's card, in the order of `panes`. A card stays on screen while its place does: a session
    /// taking the place of another (a tab switch, a new session, a rename) shows on the same card, so its
    /// terminal takes the keyboard straight from the one before and the keyboard never goes down between
    /// them. A session that opens beside another gets a card of its own.
    private(set) var cards: [Int] = []
    @ObservationIgnored private var cardsMade = 0
    var stacked: Bool { workspaces.stacked }
    var shares: CardShares { workspaces.shares }
    var layout: CardTree? { workspaces.layout }
    var floatingCards: [FloatingCard] { workspaces.floating }
    var zoomed: SessionRef? { workspaces.zoomed }
    func isFloating(_ ref: SessionRef) -> Bool { workspaces.isFloating(ref) }
    /// How many times `arrange` has moved the cards. It moves with them, and until it has arrived each
    /// terminal on screen keeps its grid (`GridHold`).
    private(set) var arrangement = 0
    private(set) var terminals: [SessionRef: TerminalModel] = [:]
    @ObservationIgnored private var unopenedScreens: [SessionRef: SavedScreen] = [:]
    private(set) var fontSize: CGFloat
    /// The terminal's typeface, from the palette's Font… list.
    private(set) var terminalFont: TerminalFont
    /// Cards meet at a hairline, edge to edge, instead of floating on the wash.
    private(set) var compactLayout: Bool
    /// The host whose sessions the strip shows.
    private(set) var hostID: String
    /// What each session's pill marks: working, finished, or waiting on him.
    private(set) var attention = AttentionBoard()
    /// Whether a session off screen chimes when it finishes or starts waiting on him.
    private(set) var soundsOn: Bool
    /// Option plus a key sends Esc and the key, as Meta does, so Option-B and Option-F move by words in
    /// the shell. Off, Option types its own characters (Option-Shift-2 is €).
    private(set) var optionAsMeta: Bool
    /// Caps Lock sends Esc.
    private(set) var capsLockAsEscape: Bool
    /// Finishing a selection copies it, without the menu's Copy.
    private(set) var copyOnSelect: Bool
    var showingPalette = false
    var showingKey = false
    /// A machine a pairing link named, waiting on his word to take its host's place.
    var pairing: PairedHost?
    /// Why the last pairing link was turned away, shown in the pairing sheet.
    var pairingProblem: String?
    /// Each host's agents' asks already answered, kept until tmux reports them cleared.
    @ObservationIgnored private var answered: [String: Set<OpenRequest>] = [:]
    var renaming: SessionRef?
    var killing: SessionRef?
    /// The open session's windows, while the palette lists them (Windows.swift).
    var windowList: WindowList?
    var renamingWindow: WindowTarget?
    /// A session action that failed, shown once as an alert.
    var problem: String?
    /// A paste waiting on him, shown as an alert.
    var pendingPaste: PendingPaste?
    /// The path picker, while it is open.
    var pathPicker: PathPicker?
    /// The inbox, while it is open (Inbox.swift).
    var inbox: Inbox?
    /// The theme picker, while it is open (ThemePicker.swift).
    var themePicker: ThemePicker?
    /// Set from the moment the search field of the palette, a picker or the inbox takes the keyboard until
    /// the keyboard is back with the terminal and has stopped moving (`takeKeyboardBack`). The field takes
    /// the keyboard without the key row above it and the terminal brings the row back, so the cards' height
    /// moves twice; meanwhile every terminal keeps its grid, and tmux is sent no size.
    var keyboardAway = false
    /// Each host's saved actions, by host id.
    var actions: [String: [SavedAction]] = [:]
    /// The page open in the preview panel.
    private(set) var preview: Preview?
    /// Set while asking which port to preview.
    var askingPort = false
    /// A short note at the foot of the screen that goes away by itself, such as why a link opened no
    /// session.
    private(set) var notice: String?
    /// The file got from the host, while Quick Look shows it (GetFile.swift).
    var fetched: URL?
    /// The name of the file on its way from the host.
    var gettingFile: String?
    /// Listening for words to type, while the dictation bubble shows (Dictation.swift).
    var dictation: Dictation?
    /// The embedding app's "Ask Akyl" callback. It takes precedence over an imported task's native return.
    var onAskAkyl: ((AskAkyl) -> Void)?
    private(set) var akylVisit: AkylVisit?
    var akylPresented = false
    private(set) var akylOpening = false
    private(set) var akylOpenProblem: String?
    @ObservationIgnored private var akylImportID: UUID?
    @ObservationIgnored private var akylKeyboard: (ref: SessionRef?, typing: Bool)?
    @ObservationIgnored private var akylReturnDocument: AkylReturnDocument?

    var canAskAkyl: Bool { onAskAkyl != nil || akylVisit?.opened == true }
    /// How many terminal spaces are on screen: the Lhûn app's window, or none while the app embedding
    /// LhunKit shows another of its spaces.
    private(set) var terminalSpaces = 0
    /// The chat cards that want each session live (SessionTerminal.swift), in the order they came on
    /// screen: the first holds it, unless the terminal space shows the session.
    private(set) var watchers: [SessionRef: [UUID]] = [:]
    /// The terminal of each session live on a chat card. It only watches (`TerminalModel.watchesOnly`).
    private(set) var watches: [SessionRef: TerminalModel] = [:]
    /// Pulling the strip down: a still picture of every session.
    let peek = SessionPeek()
    /// Every host's sessions in a column left of the cards, while the iPad is held sideways.
    let sidebar = SessionSidebar()
    /// A picture of a session's screen while the pointer rests on its pill or sidebar row.
    let hover = HoverPicture()
    /// A killed session's card fading away.
    @ObservationIgnored let fade = CardFade()
    @ObservationIgnored let keyboardMotion = KeyboardMotion()
    /// The key row over the on-screen keyboard, which every terminal shows.
    @ObservationIgnored let keyRow = KeyRow()

    @ObservationIgnored private let client: String
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var sawFirstPath = false
    @ObservationIgnored private var networkUp = true
    @ObservationIgnored private var reachWatch: Task<Void, Never>?
    /// Present only when launched with `-probe YES`.
    @ObservationIgnored private(set) var probe: Probe?
    @ObservationIgnored let pathListings = PathListings()
    @ObservationIgnored private var noticeClear: Task<Void, Never>?
    /// Identity, not just a session name: two imports can ask for the same session with different tasks.
    private struct RequestedOpen: Equatable {
        let id = UUID()
        let ref: SessionRef
        let akylToken: String?
    }
    @ObservationIgnored private var requested: RequestedOpen?
    /// The programs' finishes he has seen, as last saved.
    @ObservationIgnored private var savedFinishes: [SessionRef: Set<String>] = [:]
    /// How much and how lately he ran each palette row, so Recent and the ranking lift the rows he runs.
    @ObservationIgnored private(set) var paletteUses = PaletteUses()
    /// The scene's phase as last acted on, so a phase that both the terminal space and the app report is
    /// acted on once.
    @ObservationIgnored private var phase: ScenePhase?

    static let defaultFontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 15 : 12
    private static let fontSizes: ClosedRange<CGFloat> = 10...28

    private enum Defaults {
        static let fontSize = "fontSize"
        static let selection = "selection"
        static let panes = "panes"
        static let stacked = "stacked"
        static let shares = "shares"
        static let workspaces = "workspaces"
        static let host = "host"
        static let keySeen = "keySeen"
        static let client = "client"
        static let sounds = "sounds"
        static let optionAsMeta = "optionAsMeta"
        static let capsLockAsEscape = "capsLockAsEscape"
        static let copyOnSelect = "copyOnSelect"
        static let compactLayout = "compactLayout"
        static let seenFinishes = "seenFinishes"
        static let paletteUses = "paletteUses"
        static let akylVisit = "akylVisit"
    }

    init() {
        let defaults = LhunDefaults.shared
        do {
            #if targetEnvironment(simulator)
            let key = try DeviceKey.simulator()
            #else
            let key = try DeviceKey.loadOrCreate()
            #endif
            self.key = key
            keyProblem = nil
            links = Host.all.map { HostLink(host: $0, key: key) }
        } catch {
            key = nil
            keyProblem = error.localizedDescription
            links = []
        }
        let storedSize = defaults.double(forKey: Defaults.fontSize)
        fontSize = storedSize > 0 ? storedSize : Self.defaultFontSize
        soundsOn = defaults.object(forKey: Defaults.sounds) as? Bool ?? true
        // bool(forKey:) also reads a launch argument such as `-optionAsMeta NO`.
        optionAsMeta = defaults.object(forKey: Defaults.optionAsMeta) == nil || defaults.bool(forKey: Defaults.optionAsMeta)
        capsLockAsEscape = defaults.bool(forKey: Defaults.capsLockAsEscape)
        copyOnSelect = defaults.bool(forKey: Defaults.copyOnSelect)
        compactLayout = defaults.bool(forKey: Defaults.compactLayout)
        terminalFont = .chosen
        hostID = defaults.string(forKey: Defaults.host) ?? Host.all.first?.id ?? ""
        // Names this device's tmux clients on the hosts, so a reattach can find its own stale client.
        if let stored = defaults.string(forKey: Defaults.client) {
            client = stored
        } else {
            client = String(UUID().uuidString.prefix(8)).lowercased()
            defaults.set(client, forKey: Defaults.client)
        }
        showingKey = key != nil && !defaults.bool(forKey: Defaults.keySeen)
        // A program's done or error he has looked at stays seen when Lhûn comes back.
        let finishes = defaults.dictionary(forKey: Defaults.seenFinishes) as? [String: [String]] ?? [:]
        savedFinishes = Dictionary(
            finishes.compactMap { line, seen in SessionRef(line: line).map { ($0, Set(seen)) } }, uniquingKeysWith: { a, _ in a }
        )
        attention = AttentionBoard(seenFinishes: savedFinishes)
        paletteUses = PaletteUses(stored: defaults.object(forKey: Defaults.paletteUses))

        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(path) }
        }
        monitor.start(queue: .main)
        for link in links { wire(link) }
        keyRow.onPath = { [weak self] in self?.togglePathPicker() }
        keyRow.onDictate = { [weak self] in self?.toggleDictation() }
        keyRow.onEscape = { [weak self] in self?.escapeDictation() ?? false }

        // Before the saved session opens, so its terminal is measured too.
        if Probe.isOn {
            probe = Probe(
                terminals: { [weak self] in self.map { Array($0.terminals.values) } ?? [] },
                selection: { [weak self] in self?.selection },
                listed: { [weak self] in self?.links.reduce(0) { $0 + $1.sessions.count } ?? 0 }
            )
        }
        let legacy = WorkspaceStore(
            selection: defaults.string(forKey: Defaults.selection).flatMap { SessionRef(line: $0) },
            panes: (defaults.string(forKey: Defaults.panes) ?? "").split(separator: "\n").compactMap { SessionRef(line: $0) },
            stacked: defaults.bool(forKey: Defaults.stacked),
            shares: CardShares(stored: defaults.dictionary(forKey: Defaults.shares) as? [String: Double] ?? [:])
        )
        if let saved = defaults.data(forKey: Defaults.workspaces) {
            do { workspaces = try PropertyListDecoder().decode(WorkspaceStore.self, from: saved) }
            catch {
                workspaces = legacy
                problem = "The saved tabs couldn't be read. Your remote sessions are unchanged."
            }
        } else {
            workspaces = legacy
            remember()
        }
        updateCards(from: [], cards: [])
        unopenedScreens = SavedScreens.load()
        for ref in panes { attach(ref) }
        if let selection { attention.opened(selection) }
        if let data = defaults.data(forKey: Defaults.akylVisit) {
            do { akylVisit = try AkylDocument.decoder().decode(AkylVisit.self, from: data) }
            catch { problem = "The saved Akyl task link can't be read. Your sessions are unchanged. Open the task again from Akyl." }
        }
    }

    var selectedTerminal: TerminalModel? {
        selection.flatMap { terminals[$0] }
    }

    var currentLink: HostLink? {
        links.first { $0.host.id == hostID } ?? links.first
    }

    /// Where a session is, as one fact beside its name: its host when that is not the one open, else its
    /// folder.
    func whereabouts(of session: TmuxSession, on host: Host) -> String {
        host.id == currentLink?.host.id ? session.folder : "on \(host.name)"
    }

    /// Every session on every host, in list order.
    var order: [SessionRef] {
        links.flatMap { link in link.sessions.map { SessionRef(host: link.host.id, name: $0.name) } }
    }

    func link(for ref: SessionRef) -> HostLink? {
        links.first { $0.host.id == ref.host }
    }

    func tabRoot(for ref: SessionRef) -> SessionRef { workspaces.tabRoot(for: ref) }

    func tabMembers(_ ref: SessionRef) -> [SessionRef] { workspaces.tabMembers(ref) }

    func tabSessions(on link: HostLink) -> [TmuxSession] {
        link.sessions.filter {
            let ref = SessionRef(host: link.host.id, name: $0.name)
            return tabRoot(for: ref) == ref
        }
    }

    var tabOrder: [SessionRef] {
        links.flatMap { link in tabSessions(on: link).map { SessionRef(host: link.host.id, name: $0.name) } }
    }

    // MARK: Lifecycle

    /// The scene's phase: from the terminal space while it is on screen, else from the app (`Lhun`). A
    /// phase told by both acts once.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != self.phase else { return }
        self.phase = phase
        switch phase {
        case .active:
            probe?.becameActive()
            for terminal in terminals.values { terminal.setInBackground(false) }
            // Off screen, the terminal space's cards draw again as they come back on screen (TerminalHost).
            if terminalSpaceShown {
                for ref in shownPanes { terminals[ref]?.setVisible(true) }
            }
            for terminal in watches.values {
                terminal.setInBackground(false)
                terminal.setVisible(true)
            }
            for link in links { link.redial() }
            preview?.open()
            recheckTerminals()
            refreshLists()
        case .background:
            // Off screen, no terminal keeps a Metal view; the open one builds its own again on return.
            for terminal in terminals.values {
                terminal.setVisible(false)
                terminal.setInBackground(true)
            }
            for terminal in watches.values {
                terminal.setVisible(false)
                terminal.setInBackground(true)
            }
            // Nothing listens on this device's loopback while Lhûn is off screen.
            preview?.stop()
            // iOS may end Lhûn while it is away; the next launch shows these until tmux redraws.
            var screens = unopenedScreens
            for (ref, terminal) in terminals { screens[ref] = terminal.savedScreen }
            SavedScreens.save(screens)
            probe?.enteredBackground()
        default:
            break
        }
    }

    func keyShown() {
        LhunDefaults.shared.set(true, forKey: Defaults.keySeen)
    }

    /// The pairing sheet closed: a machine still waiting on his word is let go.
    func pairingSheetClosed() {
        pairing = nil
        pairingProblem = nil
        keyShown()
    }

    /// The app embedding LhunKit put this device's key on the Mac (`Lhun.keyInstalled`). The key sheet has
    /// done its work, and every host dials again at once, as does every terminal waiting to retry.
    func keyInstalled() {
        showingKey = false
        keyShown()
        for link in links { link.redial() }
        recheckTerminals()
        refreshLists()
    }

    /// Hears the link's reports and the clients that come to its sessions.
    private func wire(_ link: HostLink) {
        link.onReports = { [weak self] link, seen in self?.watched(link, seen: seen) }
        link.onListed = { [weak self] link in
            guard let self else { return }
            let names = Set(link.sessions.map(\.name))
            let missing = workspaces.unlisted(
                on: link.host.id, sessions: names, attached: Set(terminals.keys)
            )
            for ref in unopenedScreens.keys.filter({ $0.host == link.host.id && !names.contains($0.name) }) {
                unopenedScreens[ref] = nil
            }
            if !missing.isEmpty { closeMembers(missing, typing: false, forgettingShares: true) }
        }
        // A screen that comes to a session open here keeps its size (SharedSize).
        link.onJoined = { [weak self] link, session in
            self?.terminals[SessionRef(host: link.id, name: session)]?.clientJoined()
        }
    }

    /// A pairing link pasted or opened: the machine it names waits on his word (`pair`). A link Lhûn can't
    /// sign in with is turned away, saying so in the sheet.
    func offerPairing(_ paired: PairedHost?) {
        showingKey = key != nil
        guard let paired, (try? paired.hostKeys.map(NIOSSHPublicKey.init(openSSHPublicKey:))) != nil else {
            pairing = nil
            pairingProblem = "That isn't a pairing link Lhûn can use. Copy the whole link the setup printed."
            return
        }
        pairingProblem = nil
        pairing = paired
    }

    /// Puts the paired machine in its host's place. The sessions open on the machine it replaces let go, since
    /// that machine's tmux is not the new one's, and the strip shows the new machine.
    func pair(_ paired: PairedHost) {
        pairing = nil
        pairingProblem = nil
        guard let key else { return }
        do { try PairedHosts.keep(paired) } catch {
            problem = "Lhûn couldn't keep the pairing: \(error.localizedDescription)"
            return
        }
        guard let host = Host.all.first(where: { $0.id == paired.id }) else { return }
        let replaced = Set(terminals.keys.filter { $0.host == host.id })
            .union(workspaces.groups.flatMap(\.members).filter { $0.host == host.id })
        for ref in replaced { detach(ref) }
        for ref in watches.keys where ref.host == host.id { watches.removeValue(forKey: ref)?.detach() }
        let index = links.firstIndex(where: { $0.host.id == paired.id })
        if let index { links[index].redial() }
        let link = HostLink(host: host, key: key)
        wire(link)
        if let index {
            links[index] = link
        } else if host.id == Host.mac.id {
            links.insert(link, at: 0)
        } else {
            links.append(link)
        }
        showingKey = false
        keyShown()
        switchHost(to: link)
        note("Paired \(paired.machine) as \(host.phrase).")
    }

    /// Lists every host's sessions again. Lists refresh on events, never on a timer: the app coming back,
    /// the palette opening, a session starting or ending, the network changing.
    func refreshLists() {
        Task { await refreshAll() }
    }

    // MARK: Sessions

    func switchHost(to link: HostLink) {
        cancelRequestedOpen()
        hostID = link.host.id
        LhunDefaults.shared.set(hostID, forKey: Defaults.host)
        Task { await link.refresh() }
    }

    func selectTab(_ ref: SessionRef) {
        showWorkspace(ref, restoringFocus: true)
    }

    func select(_ ref: SessionRef) {
        showWorkspace(ref, restoringFocus: false)
    }

    private func showWorkspace(_ ref: SessionRef, restoringFocus: Bool) {
        cancelRequestedOpen()
        closePeek()
        for member in tabMembers(ref) { attach(member) }
        let revealsCard = !restoringFocus && panes.contains(ref) && zoomed != nil && zoomed != ref
        let change = {
            self.changeWorkspace(activatingHost: true) {
                if restoringFocus { $0.selectTab(ref) }
                else { $0.selectMember(ref) }
            }
        }
        if revealsCard { arrange(change) }
        else { change() }
    }

    private func changeWorkspace(activatingHost: Bool = false, _ change: (inout WorkspaceStore) -> Void) {
        let left = selection
        let previousHost = workspaces.active?.root.host
        let previous = panes
        let previousCards = cards
        change(&workspaces)
        if previous != panes { updateCards(from: previous, cards: previousCards, focused: left) }
        if let left, left != selection { link(for: left)?.look(leaving: left.name) }
        remember()
        guard let ref = selection else { return }
        let root = tabRoot(for: ref)
        if (activatingHost || ref != left || root.host != previousHost), root.host != hostID, let link = link(for: root) {
            switchHost(to: link)
        }
        guard activatingHost || ref != left else { return }
        attention.opened(ref)
        rememberFinishes()
    }

    private func attach(_ ref: SessionRef) {
        guard terminals[ref] == nil, let key, let link = link(for: ref) else { return }
        let terminal = TerminalModel(
            host: link.host, name: ref.name, key: key, client: client, fontSize: fontSize, face: terminalFont, keyRow: keyRow,
            probe: probe, watchesOnly: false
        )
        terminal.onEnded = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            self.ended(terminal)
        }
        terminal.onDropped = { [weak self] in self?.watchReach() }
        terminal.onBell = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            self.heardBell(terminal)
        }
        terminal.view.onEscape = { [weak self] in self?.escapeDictation() ?? false }
        terminal.view.onActionKey = { [weak self] key in self?.handleActionKey(key) ?? false }
        terminal.onPreview = { [weak self, weak terminal] port in
            guard let self, let terminal, let link = self.link(for: terminal.ref) else { return }
            self.openPreview(port: port, on: link)
        }
        terminal.onBlockedLink = { [weak self] in
            self?.note("Lhûn blocked that link: its address hides characters.")
        }
        terminal.view.pasteFiles = { [weak self, weak terminal] files in
            guard let self, let terminal else { return }
            self.upload(files, into: terminal)
        }
        terminal.view.pasteText = { [weak self, weak terminal] text in
            guard let self, let terminal else { return }
            self.paste(text, into: terminal)
        }
        applyKeySettings(to: terminal)
        terminal.alternateScreen = link.reports.first { $0.name == ref.name }?.alternateScreen ?? false
        terminals[ref] = terminal
        if let saved = unopenedScreens.removeValue(forKey: ref) { terminal.show(saved) }
        terminal.start()
        probe?.record("open \(ref.name)")
    }

    func step(_ offset: Int) {
        let refs = tabOrder
        guard !refs.isEmpty else { return }
        let index = selection.flatMap { refs.firstIndex(of: tabRoot(for: $0)) } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % refs.count + refs.count) % refs.count
        selectTab(refs[next])
    }

    /// Starts a session on the given host, or on the host of the open session, and opens it. It gets two
    /// words for a name, "brave-meadow", that no session on either host has.
    func newSession(on chosen: HostLink? = nil) {
        guard let link = chosen ?? selection.flatMap(link(for:)) ?? links.first else { return }
        var random = SystemRandomNumberGenerator()
        let name = SessionNames.fresh(avoiding: Set(links.flatMap(\.sessions).map(\.name)), using: &random)
        newSession(named: name, on: link)
    }

    /// Starts a session named `name` on the link's host, at home or in `folder`, and opens it.
    func newSession(named name: String, in folder: String? = nil, on link: HostLink) {
        perform(on: link) { [self] in
            _ = try await link.run(folder.map { Tmux.create(name, in: $0) } ?? Tmux.create(name))
            select(SessionRef(host: link.host.id, name: name))
        }
    }

    func rename(_ ref: SessionRef, to newName: String) {
        let name = Tmux.clean(newName)
        guard !name.isEmpty, name != ref.name, let link = link(for: ref) else { return }
        perform(on: link) { [self] in
            _ = try await link.run(Tmux.rename(ref.name, to: name))
            let renamed = SessionRef(host: ref.host, name: name)
            let saved = unopenedScreens.removeValue(forKey: ref)
            unopenedScreens[renamed] = saved
            if let terminal = terminals.removeValue(forKey: ref) {
                terminal.rename(to: name)
                terminals[renamed] = terminal
            }
            changeWorkspace { $0.rename(ref, to: renamed) }
            if workspaces.group(for: renamed) != nil { attach(renamed) }
            updateAkylBookmark(renaming: ref, to: renamed)
        }
    }

    /// Kills the session on its host. Its card fades away at once, and the next thing shows through it;
    /// should the kill fail, the session stays listed and the alert says why.
    func kill(_ ref: SessionRef) {
        guard link(for: ref) != nil else { return }
        fadeAway(ref)
        detach(ref)
        endOnHost(ref)
    }

    /// Kills every session of the tab on its host, as the × on its pill does: its cards fade away and the
    /// pill leaves the strip once the host lists its sessions again.
    func killTab(_ ref: SessionRef) {
        let members = tabMembers(ref)
        members.forEach(fadeAway)
        detachTab(ref)
        members.forEach(endOnHost)
    }

    private func fadeAway(_ ref: SessionRef) {
        if fade.start(ref, compact: compactLayout) { probe?.record("fade \(ref.name)") }
    }

    private func endOnHost(_ ref: SessionRef) {
        guard let link = link(for: ref) else { return }
        perform(on: link) { [self] in
            _ = try await link.run(Tmux.kill(ref.name))
            changeWorkspace { $0.forgetShares(of: ref) }
        }
    }

    /// Lets go of the focused card's session and leaves it running on the host.
    func detachSelected() {
        guard let ref = selection else { return }
        detach(ref)
    }

    /// Lets go of the session and leaves it running on the host. Its card leaves the screen.
    func detach(_ ref: SessionRef) {
        let typing = terminals[ref]?.view.isFirstResponder == true
        closeMembers([ref], typing: typing)
        terminals.removeValue(forKey: ref)?.detach()
    }

    func detachTab(_ ref: SessionRef) {
        let members = Set(tabMembers(ref))
        let typing = members.contains { terminals[$0]?.view.isFirstResponder == true }
        closeMembers(members, typing: typing)
        for member in members { terminals.removeValue(forKey: member)?.detach() }
    }

    func sendEscape() {
        if dictation != nil {
            cancelDictation()
            return
        }
        selectedTerminal?.view.send([0x1b])
    }

    // MARK: Preview

    /// The host a preview opens on: the open session's, or else the one the strip shows.
    var previewLink: HostLink? {
        selection.flatMap(link(for:)) ?? currentLink
    }

    /// Shows a port on a host in the preview panel, in place of whatever it showed before.
    func openPreview(port: Int, on link: HostLink) {
        preview?.stop()
        let preview = Preview(link: link, port: port)
        self.preview = preview
        preview.open()
    }

    /// Shows the port typed into the prompt, on the host a preview opens on.
    func openPreview(typed text: String) {
        guard let link = previewLink else { return }
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            problem = "Ports go from 1 to 65535."
            return
        }
        openPreview(port: port, on: link)
    }

    func closePreview() {
        preview?.stop()
        preview = nil
    }

    // MARK: Uploads

    /// Sends pasted or dropped files to the session's host one at a time, then types their paths into
    /// its terminal as one paste. Each file is read only when its turn to be sent comes, so one is in
    /// memory at a time. A file that fails stops the rest and says why; the paths of the files already
    /// sent are still typed. They go over a connection of their own, so the session list and the
    /// preview never wait behind them, and redialing the list when Lhûn comes back never cuts one off.
    func upload(_ files: [NSItemProvider], into terminal: TerminalModel) {
        guard !files.isEmpty, let link = link(for: terminal.ref) else { return }
        terminal.uploads += 1
        Task {
            var paths: [String] = []
            do {
                let connection = try await link.openConnection()
                defer { connection.close() }
                for provider in files {
                    let file = try await Upload.read(provider)
                    paths.append(try await connection.upload(file.data, named: file.name))
                }
            } catch {
                problem = error.localizedDescription
            }
            terminal.uploads -= 1
            if !paths.isEmpty { terminal.paste(paths.joined(separator: " ") + " ") }
        }
    }

    /// A paste from the clipboard. Text with a line break, into a program that does not take pastes as one
    /// piece, would run as it lands, so it waits for him to say so. Only tmux can say what the program
    /// takes, and only such text asks it.
    func paste(_ text: String, into terminal: TerminalModel) {
        guard Paste.breaksLines(text) else {
            terminal.paste(text)
            return
        }
        Task { [weak self, weak terminal] in
            guard let takes = await terminal?.paneTakesPastes(), let self, let terminal else { return }
            if takes {
                terminal.paste(text)
            } else {
                pendingPaste = PendingPaste(ref: terminal.ref, text: text)
            }
        }
    }

    func confirmPaste(_ paste: PendingPaste) {
        terminals[paste.ref]?.paste(paste.text)
    }

    // MARK: Cards

    /// The cards on screen in reading order: both, or the zoomed one alone.
    var shownPanes: [SessionRef] {
        zoomed.map { [$0] } ?? panes
    }

    /// The cards on screen in reading order, each with the session it shows.
    var shownCards: [ShownCard] {
        zip(cards, panes).filter { zoomed == nil || $1 == zoomed }.map { ShownCard(id: $0, ref: $1) }
    }

    private func updateCards(from previous: [SessionRef], cards previousCards: [Int], focused previousFocus: SessionRef? = nil) {
        let had = Dictionary(zip(previous, previousCards), uniquingKeysWith: { first, _ in first })
        var retained = Set(panes.compactMap { had[$0] })
        var handoff: Int?
        if let selection, had[selection] == nil, let previousFocus, let card = had[previousFocus], !retained.contains(card) {
            handoff = card
            retained.insert(card)
        }
        var available = previousCards.filter { !retained.contains($0) }[...]
        cards = panes.map { ref in
            if let card = had[ref] { return card }
            if ref == selection, let handoff { return handoff }
            if let card = available.popFirst() { return card }
            cardsMade += 1
            return cardsMade
        }
    }

    var isSplit: Bool { panes.count > 1 }

    var share: CGFloat { workspaces.focusedShare }

    func split(_ half: Half) {
        guard let ref = selection, panes.contains(ref), let link = link(for: ref) else { return }
        let name = Tmux.splitName(of: ref.name, after: link.sessions)
        perform(on: link) { [self] in
            do {
                _ = try await link.run(Tmux.create(name, besides: ref.name))
            } catch {
                if case SSHFailure.commandFailed(let status, _) = error, status != -1 { throw error }
                await link.refresh()
                guard link.status == .online, link.sessions.contains(where: { $0.name == name }) else { throw error }
            }
            openInWorkspace(SessionRef(host: link.host.id, name: name), on: half, over: nil, beside: ref)
        }
    }

    func open(_ ref: SessionRef, on half: Half, over covered: SessionRef?, focusing: SessionRef? = nil) {
        openInWorkspace(ref, on: half, over: covered, focusing: focusing)
    }

    private func openInWorkspace(_ ref: SessionRef, on half: Half, over covered: SessionRef?,
                                 focusing: SessionRef? = nil, beside anchor: SessionRef? = nil) {
        cancelRequestedOpen()
        closePeek()
        attach(ref)
        if let anchor, workspaces.group(for: anchor) == nil {
            changeWorkspace(activatingHost: true) { $0.selectMember(ref) }
            return
        }
        let target = anchor.flatMap { workspaces.group(for: $0) } ?? workspaces.active
        let covered = anchor ?? covered
        for member in target?.members ?? [] { attach(member) }
        arrange {
            changeWorkspace(activatingHost: true) { $0.open(ref, on: half, over: covered, focusing: focusing, beside: anchor) }
        }
    }

    func toggleZoom(_ ref: SessionRef) {
        guard isSplit, panes.contains(ref) else { return }
        arrange { changeWorkspace { $0.toggleZoom(ref) } }
    }

    /// A tap on a card gives it the focus.
    func focusCard(_ ref: SessionRef) {
        guard panes.contains(ref) else { return }
        select(ref)
    }

    func focusCard(by offset: Int) {
        let order = workspaces.focusOrder
        guard let ref = selection, let index = order.firstIndex(of: ref), order.count > 1 else { return }
        let next = index + offset
        guard order.count > 2 || order.indices.contains(next) else { return }
        select(order[(next % order.count + order.count) % order.count])
    }

    func focusOtherCard() {
        let order = workspaces.focusOrder
        guard let ref = selection, let index = order.firstIndex(of: ref), order.count > 1 else { return }
        select(order[(index + 1) % order.count])
    }

    func resize(to share: CGFloat) {
        guard let path = workspaces.focusedSplit else { return }
        resize(splitAt: path, to: share)
    }

    func resize(splitAt path: [Int], to share: CGFloat) {
        guard isSplit else { return }
        changeWorkspace { $0.resize(at: path, to: share) }
        probe?.record("gap let go", details: ["share": (share * 100).rounded() / 100])
    }

    func balanceCards() {
        guard let path = workspaces.focusedSplit else { return }
        resize(splitAt: path, to: 0.5)
    }

    func resizeFocusedSplit(by offset: CGFloat) {
        guard let path = workspaces.focusedSplit else { return }
        resize(splitAt: path, to: workspaces.focusedShare + (workspaces.focusedIsFirst ? offset : -offset))
    }

    func toggleFloatingCard(_ ref: SessionRef) {
        guard panes.contains(ref) else { return }
        arrange { changeWorkspace { $0.toggleFloating(ref) } }
    }

    func moveFloatingCard(_ ref: SessionRef, by change: CGSize, in size: CGSize) {
        changeWorkspace { $0.moveFloating(ref, by: change, in: size) }
    }

    func resizeFloatingCard(_ ref: SessionRef, by change: CGSize, in size: CGSize) {
        changeWorkspace { $0.resizeFloating(ref, by: change, in: size) }
    }

    /// Takes the session's card off the screen. The other card, if there is one, fills the area and takes
    /// the focus, and the keyboard with it when the closing card's terminal had it (`typing`). It takes the
    /// keyboard here, while that terminal is still in the window: left to the focus, which hands it over
    /// once SwiftUI's update is over, the keyboard went down as the closing card left and came back up
    /// 100 ms later.
    private func closeMembers(_ refs: Set<SessionRef>, typing: Bool, forgettingShares: Bool = false) {
        for ref in refs { unopenedScreens[ref] = nil }
        let visible = panes.contains { refs.contains($0) }
        let next = selection.flatMap { refs.contains($0) ? nil : $0 } ?? panes.first { !refs.contains($0) }
        if typing, let next, let view = terminals[next]?.view, view.window != nil { _ = view.becomeFirstResponder() }
        let change = {
            self.changeWorkspace {
                $0.remove(refs)
                if forgettingShares { for ref in refs { $0.forgetShares(of: ref) } }
            }
        }
        if visible && isSplit { arrange(change) }
        else { change() }
        updateAkylBookmark(removing: refs)
    }

    /// Moves the cards with one animation, and `arrangement` with them. Until it has run its course each
    /// terminal keeps its grid, and then each fits once, so tmux sees one size change instead of one per
    /// frame. With Reduce Motion on, the cards take their places at once, and each fits once then.
    ///
    /// The focus that goes with the move changes inside `change`, and nothing the cards show changes after
    /// it in the same turn. SwiftUI draws the move the moment a later change begins, reads the value that
    /// change is about to replace, and is never told the new one: a focus set after the move left the card
    /// the move brought in unfocused, and nothing took the keyboard.
    func arrange(_ change: () -> Void) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        probe?.record("arrange", details: ["animated": animated])
        guard animated else { return change() }
        withAnimation(.smooth(duration: 0.3)) {
            arrangement += 1
            change()
        }
    }

    private func remember() {
        do {
            let defaults = LhunDefaults.shared
            defaults.set(try PropertyListEncoder().encode(workspaces), forKey: Defaults.workspaces)
            for key in [Defaults.selection, Defaults.panes, Defaults.stacked, Defaults.shares] {
                defaults.removeObject(forKey: key)
            }
        } catch {
            problem = "Lhûn couldn't save the open tabs on this device. Your remote sessions are unchanged."
        }
    }

    // MARK: Text size

    func zoom(by step: CGFloat) {
        setFontSize(fontSize + step)
    }

    func resetZoom() {
        setFontSize(Self.defaultFontSize)
    }

    /// The terminal on screen takes the new size at once; the others take it when next shown, so tmux
    /// never resizes a session nobody is looking at.
    func setFontSize(_ size: CGFloat) {
        let size = min(max(size.rounded(), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard size != fontSize else { return }
        fontSize = size
        LhunDefaults.shared.set(Double(size), forKey: Defaults.fontSize)
    }

    /// The terminal on screen takes the new face at once and the others when next shown, as with size.
    func setTerminalFont(_ font: TerminalFont) {
        guard font != terminalFont else { return }
        terminalFont = font
        LhunDefaults.shared.set(font.rawValue, forKey: TerminalFont.defaultsKey)
    }

    // MARK: Layout

    /// Switches at once rather than sliding: it is picked from the palette, whose closing moves the
    /// on-screen keyboard at the same moment, and a slide under the keyboard's own animation ended early
    /// and let the terminals send tmux the widths partway through.
    func toggleCompactLayout() {
        compactLayout.toggle()
        LhunDefaults.shared.set(compactLayout, forKey: Defaults.compactLayout)
    }

    // MARK: Attention

    func toggleSounds() {
        soundsOn.toggle()
        LhunDefaults.shared.set(soundsOn, forKey: Defaults.sounds)
    }

    // MARK: Keys

    func toggleOptionAsMeta() {
        optionAsMeta.toggle()
        LhunDefaults.shared.set(optionAsMeta, forKey: Defaults.optionAsMeta)
        for terminal in terminals.values { applyKeySettings(to: terminal) }
    }

    func toggleCapsLockAsEscape() {
        capsLockAsEscape.toggle()
        LhunDefaults.shared.set(capsLockAsEscape, forKey: Defaults.capsLockAsEscape)
        for terminal in terminals.values { applyKeySettings(to: terminal) }
    }

    func toggleCopyOnSelect() {
        copyOnSelect.toggle()
        LhunDefaults.shared.set(copyOnSelect, forKey: Defaults.copyOnSelect)
        for terminal in terminals.values { applyKeySettings(to: terminal) }
    }

    private func applyKeySettings(to terminal: TerminalModel) {
        terminal.view.optionAsMetaKey = optionAsMeta
        terminal.view.capsLockAsEscape = capsLockAsEscape
        terminal.view.copyOnSelect = copyOnSelect
    }

    private func watched(_ link: HostLink, seen: Set<String>) {
        // Read, not written through: a write would tell every view of `terminals` it changed.
        for report in link.reports {
            guard let terminal = terminals[SessionRef(host: link.host.id, name: report.name)] else { continue }
            terminal.alternateScreen = report.alternateScreen
        }
        let seen = Set(seen.map { SessionRef(host: link.host.id, name: $0) })
        chime(for: attention.update(host: link.host.id, sessions: link.reports, open: selection, seen: seen))
        rememberFinishes()
        openRequested(on: link)
    }

    /// An agent in a session on screen asked for another session beside it (`lhun open`, tools/agents). It
    /// opens on the half asked for, as a split would, the keyboard staying with the agent, and the ask is
    /// cleared, which tells the agent he sees it. An ask from a session off screen waits, and the agent
    /// clears it when nobody answers.
    private func openRequested(on link: HostLink) {
        let host = link.host.id
        answered[host, default: []].formIntersection(link.reports.flatMap(\.openRequests))
        for report in link.reports {
            let asker = SessionRef(host: host, name: report.name)
            guard panes.contains(asker) else { continue }
            for request in report.openRequests where answered[host, default: []].insert(request).inserted {
                perform(on: link) { [self] in
                    _ = try await link.run(Tmux.clearOpenRequest(of: request.pane))
                    openInWorkspace(SessionRef(host: host, name: request.session), on: request.below ? .bottom : .right,
                                    over: nil, focusing: asker, beside: asker)
                }
            }
        }
    }

    /// Keeps the programs' finishes he has seen for the next launch, whenever they change.
    private func rememberFinishes() {
        let seen = attention.seenFinishes
        guard seen != savedFinishes else { return }
        savedFinishes = seen
        LhunDefaults.shared.set(
            Dictionary(uniqueKeysWithValues: seen.map { ($0.key.line, $0.value.sorted()) }), forKey: Defaults.seenFinishes
        )
    }

    /// A palette row ran: it counts towards Recent and its rank, here and after the next launch.
    func ranFromPalette(_ id: String) {
        paletteUses.ran(id, at: .now)
        LhunDefaults.shared.set(paletteUses.stored, forKey: Defaults.paletteUses)
    }

    /// Lhûn's own terminals hear the bells tmux never flags: ones in the window an attached client shows.
    private func heardBell(_ terminal: TerminalModel) {
        guard let ref = terminals.first(where: { $0.value === terminal })?.key else { return }
        if attention.heardBell(ref, open: selection) { chime(for: [ref]) }
    }

    /// The probe log keeps each chime that played and the sessions it was for, so a device run can show
    /// the sound fired, and for which session.
    private func chime(for sessions: [SessionRef]) {
        guard !sessions.isEmpty, soundsOn, Chime.play() else { return }
        probe?.chimed(sessions)
    }

    // MARK: Chat cards

    /// Whether a terminal space is on screen. A session it shows is live there and on no chat card.
    var terminalSpaceShown: Bool {
        terminalSpaces > 0
    }

    func terminalSpaceAppeared() {
        terminalSpaces += 1
    }

    func terminalSpaceDisappeared() {
        terminalSpaces -= 1
    }

    /// The chat card a session is live on: the first on screen that wants it, unless the terminal space
    /// shows the session.
    func watchHolder(of ref: SessionRef) -> UUID? {
        terminalSpaceShown && shownPanes.contains(ref) ? nil : watchers[ref]?.first
    }

    /// A chat card showing `ref` came on screen.
    func wantLive(_ ref: SessionRef, by card: UUID) {
        guard watchers[ref]?.contains(card) != true else { return }
        watchers[ref, default: []].append(card)
    }

    /// A chat card showing `ref` left the screen. The next card that wants the session takes it over; with
    /// none left, the session's chat-card terminal lets go of it.
    func letGoLive(_ ref: SessionRef, by card: UUID) {
        watchers[ref]?.removeAll { $0 == card }
        if watchers[ref]?.isEmpty == true { watchers[ref] = nil }
        settleWatch(ref)
    }

    /// Attaches the session's chat-card terminal while a card holds the session, and detaches it once none
    /// does: the terminal space took the session, or the last card that wanted it left.
    func settleWatch(_ ref: SessionRef) {
        if watchHolder(of: ref) == nil {
            watches.removeValue(forKey: ref)?.detach()
        } else if watches[ref] == nil {
            startWatch(ref)
        }
    }

    private func startWatch(_ ref: SessionRef) {
        guard let key, let link = link(for: ref) else { return }
        // A client name of its own, so attaching never stops the terminal space's client of the session.
        let terminal = TerminalModel(
            host: link.host, name: ref.name, key: key, client: client + "-watch", fontSize: fontSize, face: terminalFont,
            keyRow: keyRow, probe: nil, watchesOnly: true
        )
        // A session that ends leaves its cards the latest still picture of it.
        terminal.onEnded = { [weak self, weak terminal] in
            guard let self, let terminal, self.watches[ref] === terminal else { return }
            self.watches[ref] = nil
        }
        terminal.onDropped = { [weak self] in self?.watchReach() }
        watches[ref] = terminal
        terminal.start()
    }

    // MARK: Links

    /// Opens the session a `lhun://open?host=…&session=…` link names. The hosts' alert notifications
    /// carry one (tools/alerts), so tapping a notification lands on the session that rang. A
    /// `lhun://pair` link, scanned from the QR code the pairing setup draws, offers its machine.
    func open(_ url: URL) {
        if url.host() == "pair" { return offerPairing(Pairing.host(in: url)) }
        guard let ref = LhunLink.session(in: url), let link = link(for: ref) else {
            note("Lhûn can't open that link.")
            return
        }
        open(ref, on: link)
    }

    /// Opens only an existing listed session, never creates one or selects a document's optional window.
    func open(_ ref: SessionRef, on link: HostLink, akylToken: String? = nil) {
        cancelRequestedOpen()
        let request = RequestedOpen(ref: ref, akylToken: akylToken)
        requested = request
        if akylToken != nil { akylOpening = true; akylOpenProblem = nil }
        if link.sessions.contains(where: { $0.name == ref.name }) {
            completeOpen(request)
        } else {
            Task { await openWhenListed(request, on: link) }
        }
    }

    private func completeOpen(_ request: RequestedOpen) {
        guard requested == request else { return }
        requested = nil
        akylOpening = false
        if let token = request.akylToken {
            guard var visit = akylVisit, visit.context.token == token else { return }
            visit.opened = true
            guard saveAkylVisit(visit) else { return }
        }
        select(request.ref)
    }

    private func cancelRequestedOpen() {
        requested = nil
        akylImportID = nil
        if akylOpening {
            akylOpening = false
            akylOpenProblem = "Opening the task session was interrupted. Retry it or return to Akyl."
        }
    }

    /// The same existing bounded network refresh; a later request, even for the same session, wins.
    private func openWhenListed(_ request: RequestedOpen, on link: HostLink) async {
        var pauses = [1, 2, 4][...]
        await link.refresh()
        while link.status == .unreachable, let pause = pauses.popFirst() {
            try? await Task.sleep(for: .seconds(pause))
            guard requested == request else { return }
            await link.refresh()
        }
        guard requested == request else { return }
        if link.sessions.contains(where: { $0.name == request.ref.name }) {
            completeOpen(request)
            return
        }
        requested = nil
        akylOpening = false
        let message = link.status == .online
            ? "No session named “\(request.ref.name)” on \(link.host.phrase)."
            : "Can't reach \(link.host.phrase) to open “\(request.ref.name)”."
        if request.akylToken != nil { akylOpenProblem = message }
        else if request.ref.host != hostID { switchHost(to: link) }
        note(message)
    }

    // MARK: Native Akyl documents

    func importAkylTask(_ url: URL) {
        guard akylVisit?.pending?.selected == nil else {
            problem = "There is still selected text for the current Akyl task. Return it or explicitly discard it before opening another task."
            showAkylPreview()
            return
        }
        cancelRequestedOpen()
        let id = UUID()
        akylImportID = id
        let previous = workspaces.bookmark(host: hostID)
        Task { [weak self] in
            do {
                let context = try await Task.detached { try AkylDocument.read(url) }.value
                guard let self, akylImportID == id else { return }
                guard akylVisit?.pending?.selected == nil else {
                    akylImportID = nil
                    problem = "Selected text arrived while the document was opening. It was kept; return or explicitly discard it first."
                    showAkylPreview()
                    return
                }
                try AkylReturnDocument.discardFile()
                let bookmark = akylVisit?.context.token == context.token ? akylVisit?.previous ?? previous : previous
                let visit = AkylVisit(context: context, previous: bookmark)
                guard saveAkylVisit(visit) else { akylImportID = nil; return }
                akylImportID = nil
                akylReturnDocument = nil
                openAkylTaskSession()
            } catch {
                guard let self, akylImportID == id else { return }
                akylImportID = nil
                problem = "Lhûn couldn't read this Akyl task document. It may be unavailable or incompatible. Your existing task link, selected text and sessions were kept."
            }
        }
    }

    func openAkylTaskSession() {
        guard let visit = akylVisit else { return }
        let place = visit.context.terminalPlace
        let ref = SessionRef(host: place.host, name: place.session)
        guard let link = link(for: ref) else {
            akylOpenProblem = "This task names a host Lhûn doesn't have. Return to Akyl to choose an available session."
            return
        }
        open(ref, on: link, akylToken: visit.context.token)
    }

    private func saveAkylVisit(_ visit: AkylVisit?) -> Bool {
        do {
            if let visit {
                LhunDefaults.shared.set(try AkylDocument.encoder().encode(visit), forKey: Defaults.akylVisit)
            } else {
                LhunDefaults.shared.removeObject(forKey: Defaults.akylVisit)
            }
            akylVisit = visit
            return true
        } catch {
            problem = "Lhûn couldn't keep the Akyl task link on this device. Nothing was returned or discarded."
            return false
        }
    }

    func captureAkylReturn(about ref: SessionRef, text: String?) {
        guard var visit = akylVisit, visit.opened else { return }
        let returned = AkylTaskReturn.capturing(
            text, context: visit.context, host: ref.host, session: ref.name, at: Date()
        )
        guard visit.stage(returned) else {
            problem = "Your earlier selected text is still waiting. Return it or explicitly discard it before replacing it."
            showAkylPreview()
            return
        }
        guard saveAkylVisit(visit) else { return }
        showAkylPreview()
    }

    func showAkylPreview() {
        guard akylVisit != nil, !akylPresented else { return }
        akylKeyboard = (selection, selectedTerminal?.view.isFirstResponder == true)
        keyboardAway = true
        akylPresented = true
    }

    func closeAkylPreview() {
        let keyboard = akylKeyboard
        akylKeyboard = nil
        if keyboard?.typing == true, keyboard?.ref == selection { focusTerminal() }
        else {
            Task {
                await keyboardMotion.stillness()
                if !akylPresented, pathPicker == nil, inbox == nil, themePicker == nil, !showingPalette { keyboardAway = false }
            }
        }
    }

    func discardAkylSelection() {
        guard var visit = akylVisit else { return }
        guard discardAkylReturnFile() else { return }
        visit.pending = nil
        visit.recipient = nil
        visit.deliveryNote = nil
        guard saveAkylVisit(visit) else { return }
        akylReturnDocument = nil
    }

    func restoreBeforeAkyl() {
        guard let previous = akylVisit?.previous else { return }
        cancelRequestedOpen()
        let restored = previous.panes.compactMap { SessionRef(line: $0) }
        for ref in restored { attach(ref) }
        arrange {
            changeWorkspace { $0.restore(previous) }
            hostID = previous.host
            LhunDefaults.shared.set(hostID, forKey: Defaults.host)
        }
    }

    private func updateAkylBookmark(renaming ref: SessionRef, to renamed: SessionRef) {
        guard var visit = akylVisit, visit.previous.panes.contains(ref.line) else { return }
        visit.previous.rename(ref, to: renamed)
        _ = saveAkylVisit(visit)
    }

    private func updateAkylBookmark(removing refs: Set<SessionRef>) {
        guard var visit = akylVisit else { return }
        let removed = Set(refs.map(\.line))
        guard visit.previous.panes.contains(where: removed.contains) else { return }
        visit.previous.remove(refs)
        _ = saveAkylVisit(visit)
    }

    func removeAkylLink() {
        guard discardAkylReturnFile() else { return }
        restoreBeforeAkyl()
        guard saveAkylVisit(nil) else { return }
        akylReturnDocument = nil
        akylOpenProblem = nil
        akylPresented = false
    }

    private func discardAkylReturnFile() -> Bool {
        do {
            if let document = akylReturnDocument { try document.discard() }
            else { try AkylReturnDocument.discardFile() }
            return true
        } catch {
            problem = "The local return document couldn't be removed. Your task link and full selected text were kept."
            return false
        }
    }

    func openAkylReturn(from anchor: UIView, includingSelection: Bool) {
        guard var visit = akylVisit else { return }
        let returned: AkylTaskReturn
        if includingSelection {
            guard let pending = visit.pending, pending.selected != nil else { return }
            returned = pending
        } else {
            returned = .back(version: visit.context.version, token: visit.context.token)
        }
        if visit.pending == nil { visit.pending = returned }
        guard saveAkylVisit(visit) else { return }
        let pendingAtStart = visit.pending
        let token = visit.context.token
        do {
            let document = try AkylReturnDocument(returned)
            akylReturnDocument = document
            document.onReceipt = { [weak self, weak document] recipient, note in
                guard let self, let document, akylReturnDocument === document,
                      var current = akylVisit, current.context.token == token, current.pending == pendingAtStart else { return }
                current.recipient = recipient
                current.deliveryNote = note
                _ = saveAkylVisit(current)
            }
            document.present(from: anchor)
        } catch {
            problem = "Lhûn couldn't prepare the return document. The full selection and task link are still here."
        }
    }

    func note(_ text: String) {
        notice = text
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Host commands

    /// Runs a command on the host, shows what went wrong as an alert, and lists the host's sessions again.
    func perform(on link: HostLink, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                problem = error.localizedDescription
            }
            await link.refresh()
        }
    }

    // MARK: Private

    private func ended(_ terminal: TerminalModel) {
        guard let ref = terminals.first(where: { $0.value === terminal })?.key else { return }
        terminals[ref] = nil
        closeMembers([ref], typing: terminal.view.isFirstResponder, forgettingShares: true)
        if let link = link(for: ref) {
            Task { await link.refresh() }
        }
    }

    /// The first report is the network the app launched on; every later one is a change worth checking.
    private func pathChanged(_ path: NWPath) {
        networkUp = path.status == .satisfied
        guard sawFirstPath else {
            sawFirstPath = true
            return
        }
        guard path.status == .satisfied else { return }
        for link in links { link.redial() }
        recheckTerminals()
        Task { await refreshAll(timeout: .seconds(5)) }
    }

    private func recheckTerminals() {
        for terminal in terminals.values {
            Task { await terminal.verify() }
        }
        for terminal in watches.values {
            Task { await terminal.verify() }
        }
    }

    private func refreshAll(timeout: TimeAmount = .seconds(15)) async {
        await withTaskGroup(of: Void.self) { group in
            for link in links {
                group.addTask { await link.refresh(timeout: timeout) }
            }
        }
        if links.allSatisfy({ $0.status == .unreachable }) { watchReach() }
    }

    private func watchReach() {
        guard reachWatch == nil, !links.isEmpty else { return }
        reachWatch = Task {
            var rounds = 0
            while true {
                await refreshAll(timeout: .seconds(5))
                guard networkUp, links.allSatisfy({ $0.status == .unreachable }) else { break }
                rounds += 1
                tailscaleStalled = links.count == Host.builtIn.count && rounds >= 3
                try? await Task.sleep(for: .seconds(5))
            }
            tailscaleStalled = false
            reachWatch = nil
        }
    }
}
