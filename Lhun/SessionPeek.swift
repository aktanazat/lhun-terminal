import NIOCore
import SwiftUI
import UIKit

/// Pulling the strip down shows a still picture of every session on the strip's host above the open
/// one; pulling further lays out every session on every host in a grid. Tapping a picture opens that
/// session. With a keyboard, typing in the grid narrows it to the sessions whose name, host, program or
/// folder hold the letters, in a search bar floating over it; Return opens the first.
///
/// Where the peek is lives in `state`, and in `drag` while a finger is down. The card's offset, whether
/// the deck and the card's catcher show, and what the deck shows all follow from those two alone.
/// `show(_:)` is the only writer of `state`: the pull's end, ⌘⇧\, the palette, the keys and a tap all
/// go through it, and SwiftUI animates each change.
///
/// The open session's card only moves out of the way, and keeps the height it had as the peek appeared
/// until the peek has closed and the card is home, so tmux never sees the client resize. While the peek
/// is out, the on-screen keyboard and its key row step aside and the peek has the screen below the strip;
/// a keyboard that was up comes back as the peek closes. The terminal keeps the keys meanwhile, which
/// reach the peek through `TerminalModel.keyTap`.
/// The pictures come from one `capture-pane` command per host each time the peek opens or is pulled
/// again, are painted once into bitmaps, and are dropped when the peek closes. None is a terminal view.
@MainActor @Observable
final class SessionPeek {
    /// What the pictures are painted for: the size of a grid picture, the screen's scale, each host's
    /// colors and the terminal's font. Smaller cards scale the same bitmap down.
    struct PaintSpec: Equatable, Sendable {
        var size: CGSize
        var scale: CGFloat
        var palettes: [String: Theme.Palette]
        var font: TerminalFont
    }

    /// Where the peek rests.
    private(set) var state = PeekState.closed
    /// How far the finger has moved the card from where `state` rests it; nil whenever no finger is down.
    private(set) var drag: CGFloat?
    /// Whether the peek is on screen: resting open, or under a finger. It changes with `state` and `drag`
    /// but is kept apart from them, so what reads it sees no change while a finger moves the card.
    private(set) var isShown = false
    /// The card's height as the peek appeared, which it keeps until the peek has closed and the card is
    /// home. The room below the strip grows meanwhile, as the keyboard steps aside; the card does not.
    private(set) var cardHeight: CGFloat?
    /// The room below the strip, which lays out the row and the grid.
    var area = CGSize.zero
    /// A card's title line at the reader's text size, which PulledCard keeps.
    var titleHeight = PeekLayout.titleLine
    /// The card the arrow keys have reached.
    private(set) var highlighted: SessionRef?
    private(set) var pictures: [SessionRef: CGImage] = [:]
    /// Hosts the last capture could not reach.
    private(set) var unreachable: Set<String> = []
    /// What he typed into the grid to narrow it. Kept while the peek is open, row and grid alike.
    private(set) var query = ""

    @ObservationIgnored private var screens: [String: [ScreenSnapshot]] = [:]
    @ObservationIgnored private var captures: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var paints: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var spec: PaintSpec?
    @ObservationIgnored private weak var keyboard: TerminalModel?
    @ObservationIgnored private weak var probe: Probe?

    var layout: PeekLayout { PeekLayout(area: area, cardHeight: cardHeight, titleHeight: titleHeight) }

    /// How far below its place the card sits.
    var cardOffset: CGFloat { max(0, layout.rest(in: state) + (drag ?? 0)) }

    /// What the deck behind the card shows. While a finger is down, it is where letting go would settle.
    var deck: PeekState {
        guard drag != nil else { return state }
        return cardOffset >= layout.gridFrom ? .grid : .row
    }

    /// Hands the peek the keys typed into the open terminal, and highlights `ref` when the peek is not on
    /// screen yet. `keys` returns whether it used them; the rest go on to tmux.
    func present(
        highlighting ref: SessionRef?, keyboard terminal: TerminalModel?, probe: Probe?,
        keys: @escaping ([UInt8]) -> Bool
    ) {
        if !isShown {
            highlighted = ref
            self.probe = probe
        }
        if keyboard !== terminal { keyboard?.keyTap = nil }
        keyboard = terminal
        terminal?.keyTap = keys
    }

    /// Moves the card with the finger, `y` points down from where it went down.
    func pull(_ y: CGFloat) {
        drag = y
        guard !isShown else { return }
        isShown = true
        if cardHeight == nil { cardHeight = area.height }
        probe?.record("peek")
    }

    /// Settles where the finger let go.
    func release(velocity: CGFloat) {
        show(layout.state(releasedAt: cardOffset, velocity: velocity))
    }

    /// Moves the peek to `next`, and SwiftUI animates the card and the deck there. With Reduce Motion on,
    /// the card goes there at once (PulledCard) and only the deck fades.
    func show(_ next: PeekState) {
        guard next != state || drag != nil else { return }
        let appearing = !isShown
        if next == .closed {
            // The keys go back to the session at once, while the card is still sliding home.
            keyboard?.keyTap = nil
            keyboard = nil
        } else if cardHeight == nil {
            cardHeight = area.height
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth) {
            state = next
            drag = nil
            isShown = next != .closed
        } completion: { [weak self] in
            // Once the card is home, unless a pull or a key opened the peek again meanwhile.
            guard let self, !self.isShown else { return }
            self.letGo()
        }
        probe?.record(appearing ? "peek" : "peek show", details: ["state": "\(next)", "animated": !reduceMotion])
    }

    /// Moves the highlight through `refs`, the cards on screen in reading order. Up and down skip a grid
    /// row; in the row above the card, down opens the grid and up closes the peek.
    func move(_ direction: PeekKey.Direction, among refs: [SessionRef]) {
        if deck != .grid, direction == .down || direction == .up {
            show(direction == .down ? .grid : .closed)
            return
        }
        guard !refs.isEmpty else { return }
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -layout.gridColumns
        case .down: layout.gridColumns
        }
        guard let index = highlighted.flatMap(refs.firstIndex(of:)) else {
            highlighted = refs[0]
            return
        }
        highlighted = refs[min(max(index + step, 0), refs.count - 1)]
    }

    /// Narrows the grid to the sessions `query` matches and highlights the first of them.
    func filter(_ query: String, in links: [HostLink]) {
        self.query = query
        highlighted = Self.kept(by: query, in: links).first
    }

    /// The sessions the grid shows for `query`, in reading order.
    static func kept(by query: String, in links: [HostLink]) -> [SessionRef] {
        let search = FuzzyQuery(query)
        return links.flatMap { link in
            link.sessions(matching: search).map { SessionRef(host: link.host.id, name: $0.name) }
        }
    }

    /// Captures every session's screen, one command per host, and paints the pictures.
    func capture(_ links: [HostLink]) {
        for link in links {
            let host = link.host.id
            captures[host]?.cancel()
            captures[host] = Task { [weak self] in
                let output: String
                do {
                    output = try await link.run(Tmux.capture, timeout: .seconds(10))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.unreachable.insert(host)
                    return
                }
                let screens = await Task.detached(priority: .userInitiated) { Tmux.parseScreens(output) }.value
                guard let self, !Task.isCancelled else { return }
                self.unreachable.remove(host)
                self.screens[host] = screens
                self.paint(host)
            }
        }
    }

    /// Paints every picture again when the size, scale or appearance they are for changes.
    func paint(for spec: PaintSpec) {
        guard spec != self.spec else { return }
        self.spec = spec
        for host in screens.keys { paint(host) }
    }

    private func paint(_ host: String) {
        guard let spec, let screens = self.screens[host], let palette = spec.palettes[host] else { return }
        paints[host]?.cancel()
        paints[host] = Task { [weak self] in
            let painted = await Task.detached(priority: .userInitiated) {
                screens.compactMap { screen in
                    PeekPainter.picture(of: screen, palette: palette, font: spec.font, size: spec.size, scale: spec.scale)
                        .map { (screen.name, $0) }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            var pictures = self.pictures.filter { $0.key.host != host }
            for (name, picture) in painted {
                pictures[SessionRef(host: host, name: name)] = picture
            }
            self.pictures = pictures
        }
    }

    /// Lets go of everything once the card is home: its height, captures, screens and pictures.
    private func letGo() {
        cardHeight = nil
        for task in captures.values { task.cancel() }
        for task in paints.values { task.cancel() }
        captures = [:]
        paints = [:]
        screens = [:]
        spec = nil
        pictures = [:]
        unreachable = []
        highlighted = nil
        query = ""
        probe?.record("peek closed")
        probe = nil
    }
}

extension AppModel {
    /// Hands the peek the keys, and fetches the lists and every session's picture again, as each pull
    /// and each opening does.
    func beginPeek() {
        peek.present(highlighting: selection, keyboard: selectedTerminal, probe: probe) { [weak self] bytes in
            self?.peekKey(bytes) ?? false
        }
        refreshLists()
        peek.capture(links)
    }

    /// Moves the peek to `state` the way the pull's end does; opening it fetches the pictures first.
    func showPeek(_ state: PeekState) {
        if state != .closed { beginPeek() }
        peek.show(state)
    }

    func closePeek() {
        showPeek(.closed)
    }

    /// ⌘⇧\: the grid, or back to the session when the peek is open.
    func togglePeek() {
        showPeek(peek.isShown ? .closed : .grid)
    }

    /// The peek's keys. Text and Delete narrow the grid; while the row shows, they reach the session as
    /// before. Escape first empties a filter, then closes.
    private func peekKey(_ bytes: [UInt8]) -> Bool {
        guard let key = PeekKey(bytes) else { return false }
        let grid = peek.deck == .grid
        switch key {
        case .close where grid && !peek.query.isEmpty:
            peek.filter("", in: links)
        case .close:
            closePeek()
        case .open:
            if let ref = peek.highlighted { select(ref) } else { closePeek() }
        case .move(let direction):
            let refs = if grid {
                SessionPeek.kept(by: peek.query, in: links)
            } else {
                currentLink.map { link in link.sessions.map { SessionRef(host: link.host.id, name: $0.name) } } ?? []
            }
            peek.move(direction, among: refs)
        case .type(let text):
            guard grid else { return false }
            peek.filter(peek.query + text, in: links)
        case .erase:
            guard grid else { return false }
            peek.filter(String(peek.query.dropLast()), in: links)
        }
        probe?.record("peek key", details: ["key": "\(key)"])
        return true
    }
}

/// The pull that opens the peek from the strip, and moves the card while the peek is open. Only a
/// mostly vertical pull begins it, and only a downward one while the peek is closed, so the strip's
/// pills still scroll sideways.
struct PeekPull: UIGestureRecognizerRepresentable {
    let model: AppModel

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(peek: model.peek)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let peek = model.peek
        switch recognizer.state {
        case .began:
            model.beginPeek()
            peek.pull(recognizer.translation(in: recognizer.view).y)
        case .changed:
            peek.pull(recognizer.translation(in: recognizer.view).y)
        case .ended:
            peek.release(velocity: recognizer.velocity(in: recognizer.view).y)
        case .cancelled, .failed:
            peek.release(velocity: 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let peek: SessionPeek

        init(peek: SessionPeek) {
            self.peek = peek
        }

        /// On a slow pull UIKit asks while the translation is still zero, so the direction comes from the
        /// finger's velocity, as it does for the terminal's own scrolling.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x) && (velocity.y > 0 || peek.isShown)
        }
    }
}

/// Puts the card where the peek's state says and shows the deck behind it, both from that state alone.
/// While the peek is out the card keeps the height it had as the peek appeared, and the deck has the
/// whole room below the strip, the keyboard's too once it has stepped aside. The card does not follow the
/// keyboard meanwhile, so its terminal keeps its grid: fitted to the keyboard's moves, it took 3 rows and
/// back as the grid closed.
struct PulledCard: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A peek card's title line, scaled with the caption style its title is set in.
    @ScaledMetric(relativeTo: .caption) private var titleHeight: CGFloat = PeekLayout.titleLine

    func body(content: Content) -> some View {
        let peek = model.peek
        let pinned = peek.cardHeight != nil
        content
            .transformEnvironment(\.keyboardTravel) { if pinned { $0 = KeyboardTravel() } }
            .overlay {
                if peek.isShown {
                    // While the card is pulled down, a touch on it moves it or closes the peek, never
                    // reaching the terminal.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { model.closePeek() }
                        .gesture(PeekPull(model: model))
                        .accessibilityElement()
                        .accessibilityLabel("Back to the session")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("peek.card")
                }
            }
            .frame(height: peek.cardHeight, alignment: .top)
            .offset(y: peek.cardOffset)
            // With Reduce Motion on, the card moves without sliding; the deck behind it still fades.
            .transaction(value: peek.cardOffset) { if reduceMotion { $0.animation = nil } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { peek.area = $0 }
            .onChange(of: titleHeight, initial: true) { _, height in peek.titleHeight = height }
            .background(alignment: .top) {
                if peek.isShown {
                    // Once the peek closes, the deck keeps what it showed while it fades behind the card.
                    PeekDeck(shows: peek.deck)
                }
            }
    }
}

/// What the pulled-down card uncovers: the row of the strip's host's sessions, or the grid.
private struct PeekDeck: View {
    let shows: PeekState
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let peek = model.peek
        let layout = peek.layout
        let dark = colorScheme == .dark
        let palettes = Dictionary(uniqueKeysWithValues: model.links.map { ($0.host.id, ThemeStore.shared.palette(for: $0.host.id, dark: dark)) })
        let spec = SessionPeek.PaintSpec(
            size: layout.gridPicture, scale: displayScale, palettes: palettes, font: model.terminalFont
        )
        ZStack(alignment: .top) {
            if shows == .grid {
                PeekGrid(layout: layout)
                    .transition(.opacity)
            } else {
                PeekRow(layout: layout)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth, value: shows)
        .onChange(of: spec, initial: true) { _, spec in
            peek.paint(for: spec)
        }
    }
}

/// The strip's host's sessions, side by side above the card.
private struct PeekRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let layout: PeekLayout

    var body: some View {
        Group {
            if let link = model.currentLink, !link.sessions.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: PeekLayout.spacing) {
                            ForEach(link.sessions) { session in
                                PeekCard(link: link, session: session, picture: layout.rowPicture, titleHeight: layout.titleHeight)
                            }
                        }
                        .padding(.horizontal, PeekLayout.margin)
                        .padding(.vertical, PeekLayout.rowPadding)
                    }
                    .scrollIndicators(.hidden)
                    // Starts on the open session, and follows the highlight from there.
                    .onAppear {
                        if let ref = model.peek.highlighted { proxy.scrollTo(ref, anchor: .center) }
                    }
                    .onChange(of: model.peek.highlighted) { _, ref in
                        guard let ref else { return }
                        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(ref) }
                    }
                }
            } else {
                Text(model.currentLink.map { "No sessions on \($0.host.phrase)." } ?? "No hosts.")
                    .font(.callout)
                    .foregroundStyle(Theme.detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: layout.rowRest)
        .accessibilityIdentifier("peek.row")
    }
}

/// Every session on every host, host by host; while he types, only those the filter keeps, under the bar
/// that shows what he typed.
private struct PeekGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let layout: PeekLayout

    var body: some View {
        let columns = Array(
            repeating: GridItem(.fixed(layout.gridCardWidth), spacing: PeekLayout.spacing, alignment: .top),
            count: layout.gridColumns
        )
        let query = FuzzyQuery(model.peek.query)
        let shown = model.links.map { (link: $0, sessions: $0.sessions(matching: query)) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.wide) {
                    ForEach(shown, id: \.link.id) { link, sessions in
                        if query.isEmpty || !sessions.isEmpty {
                            VStack(alignment: .leading, spacing: Metrics.near) {
                                HStack(alignment: .firstTextBaseline, spacing: Metrics.near) {
                                    Text(link.host.name)
                                        .font(.footnote.weight(.semibold))
                                    if let note = note(for: link) {
                                        Text(note)
                                            .font(.footnote)
                                            .foregroundStyle(Theme.detail)
                                    }
                                }
                                .padding(.horizontal, PeekLayout.padding)
                                if !sessions.isEmpty {
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: PeekLayout.spacing) {
                                        ForEach(sessions) { session in
                                            PeekCard(
                                                link: link, session: session, picture: layout.gridPicture,
                                                titleHeight: layout.titleHeight
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !query.isEmpty, shown.allSatisfy(\.sessions.isEmpty) {
                        Text("No session matches “\(query.text)”.")
                            .font(.callout)
                            .foregroundStyle(Theme.detail)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Metrics.section)
                    }
                }
                .padding(PeekLayout.margin)
                // Room to scroll the last row out from under the bar.
                .padding(.bottom, query.isEmpty ? 0 : PeekFilter.room)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A tap between the cards goes back to the session.
                .contentShape(.rect)
                .onTapGesture { model.closePeek() }
            }
            // Starts with the open session in sight, scrolled no further than that takes: centering it
            // cut the top row of cards in half under the strip.
            .onAppear {
                if let ref = model.peek.highlighted { proxy.scrollTo(ref) }
            }
            .onChange(of: model.peek.highlighted) { _, ref in
                guard let ref else { return }
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(ref) }
            }
        }
        // Before the overlay, which the grid's identifier would otherwise take over from the bar's own.
        .accessibilityIdentifier("peek.grid")
        .overlay(alignment: .bottom) {
            if !query.isEmpty {
                PeekFilter(text: query.text) { model.peek.filter("", in: model.links) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: query.isEmpty)
    }

    /// Why a host shows no cards or no pictures: it can't be reached, is still connecting, or has no
    /// sessions. Nil while it shows them, since a host that is fine needs no word.
    private func note(for link: HostLink) -> String? {
        if model.peek.unreachable.contains(link.host.id) { return "can't reach it" }
        guard link.sessions.isEmpty else { return nil }
        return link.status == .online ? "no sessions" : "connecting"
    }
}

/// What he typed into the grid, floating over it, with a button that empties it.
private struct PeekFilter: View {
    /// What the bar takes at the grid's foot: the clear button's height, which the bar's text is kept from
    /// outgrowing, and the space under the bar.
    static let room = Metrics.touch + Metrics.inset

    let text: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: Metrics.near) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(text)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityIdentifier("peek.filter")
            Button("Clear Filter", systemImage: "xmark.circle.fill", action: clear)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("peek.filter.clear")
        }
        .font(.body)
        // Stops short of the accessibility sizes, whose line would make the bar taller than `room`.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.leading, Metrics.inset)
        .background(.regularMaterial, in: .capsule)
        // Hugs what he typed, up to a width a long filter truncates at, from its start.
        .frame(maxWidth: 420)
        .padding([.horizontal, .bottom], Metrics.inset)
    }
}

/// One session's picture, with what its active pane runs and where. Tapping it opens the session.
private struct PeekCard: View {
    let link: HostLink
    let session: TmuxSession
    let picture: CGSize
    /// The title line's height at the reader's text size (`PeekLayout.titleHeight`).
    let titleHeight: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    /// The program's mark, sized with the caption its title is set in.
    @ScaledMetric(relativeTo: .caption) private var markSize: CGFloat = 12

    var body: some View {
        let ref = SessionRef(host: link.host.id, name: session.name)
        let chrome = ThemeStore.shared.chrome(for: ref.host)
        let image = model.peek.pictures[ref]
        let isOpen = model.selection == ref
        let isHighlighted = model.peek.highlighted == ref
        Button {
            model.select(ref)
        } label: {
            VStack(alignment: .leading, spacing: PeekLayout.padding) {
                HStack(spacing: 0) {
                    HStack(spacing: Metrics.tight) {
                        ProgramIconView(command: session.command, model: session.model, size: markSize)
                        Text(session.name)
                            .font(.caption.weight(isOpen ? .semibold : .regular))
                    }
                    // The folder gives way first.
                    .layoutPriority(1)
                    SessionDetail(name: session.name, lead: "", folder: session.folder, gap: Metrics.near)
                        .font(.caption)
                        .foregroundStyle(chrome.detail)
                }
                .lineLimit(1)
                .frame(width: picture.width, height: titleHeight, alignment: .leading)
                Group {
                    if let image {
                        Image(decorative: image, scale: displayScale)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        chrome.card
                    }
                }
                .frame(width: picture.width, height: picture.height)
                .clipShape(.rect(cornerRadius: Metrics.radius(inside: PeekLayout.padding), style: .continuous))
            }
            .padding(PeekLayout.padding)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(isOpen ? chrome.raised : chrome.pill)
            }
            .overlay {
                if isHighlighted {
                    // The card the arrow keys have reached: the selection, and the one place here in the accent.
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("peek.\(ref.host).\(ref.name)")
        .accessibilityValue(image == nil ? "waiting" : "shown")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .id(ref)
    }
}
