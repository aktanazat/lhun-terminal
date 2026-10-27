import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The one screen: a strip with the host and its sessions, and the open sessions' terminals on cards.
/// Everything else lives in the command palette.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var draftName = ""
    @State private var draftPort = ""

    var body: some View {
        @Bindable var model = model
        SessionChrome {
            VStack(spacing: 0) {
                if let visit = model.akylVisit { AkylBreadcrumb(visit: visit) }
                CardArea()
                    .padding([.horizontal, .bottom], CardSurface.gutter(compact: model.compactLayout))
                    .modifier(PulledCard())
                    .modifier(KeyboardRoom())
            }
        }
        .overlayPreferenceValue(HoverSpot.self) { HoverPictureLayer(spot: $0) }
        .background(Theme.wash.ignoresSafeArea())
        .inspector(isPresented: previewShown) {
            if let preview = model.preview {
                PreviewView(preview: preview, close: model.closePreview)
                    .inspectorColumnWidth(min: 320, ideal: 520, max: 1000)
            }
        }
        .overlay {
            if model.showingPalette {
                Palette()
            }
        }
        .overlay {
            if let picker = model.pathPicker {
                PathPickerView(picker: picker)
            }
        }
        .overlay {
            if let inbox = model.inbox {
                InboxView(inbox: inbox)
            }
        }
        .overlay {
            if let picker = model.themePicker {
                ThemePickerView(picker: picker)
            }
        }
        .overlay(alignment: .bottom) {
            DictationBubble()
        }
        .overlay(alignment: .bottom) {
            NoticeLabel(text: model.notice ?? model.gettingFile.map { "Getting \($0)…" })
        }
        // A file got from the host, with Share; its copy goes once the preview closes.
        .quickLookPreview(fetchedShown)
        .sheet(isPresented: $model.showingKey, onDismiss: model.pairingSheetClosed) {
            if let key = model.key {
                PairSheet(line: key.publicKeyLine)
            }
        }
        .sheet(isPresented: $model.akylPresented, onDismiss: model.closeAkylPreview) {
            AkylCompanionPreview()
        }
        .alert("Rename Session", isPresented: present(\.renaming), presenting: model.renaming) { ref in
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") { model.rename(ref, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Preview Port", isPresented: $model.askingPort) {
            TextField("Port", text: $draftPort)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("preview.port")
            Button("Open") { model.openPreview(typed: draftPort) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Which port on \(model.previewLink?.host.phrase ?? "the host")?")
        }
        .windowRenameAlert()
        .confirmationDialog(
            "Kill \(model.killing?.name ?? "")?",
            isPresented: present(\.killing),
            titleVisibility: .visible,
            presenting: model.killing
        ) { ref in
            Button("Kill Session", role: .destructive) { model.kill(ref) }
        } message: { _ in
            Text("Everything running in it stops.")
        }
        .alert("Paste and Run?", isPresented: present(\.pendingPaste), presenting: model.pendingPaste) { paste in
            Button("Paste") { model.confirmPaste(paste) }
            Button("Cancel", role: .cancel) {}
        } message: { paste in
            let lines = Paste.lines(paste.text)
            Text(
                "The program in this session takes a paste as typed keys, so "
                    + (lines == 1 ? "the line runs" : "each of its \(lines) lines runs") + " as it arrives."
            )
        }
        .alert("That didn't work", isPresented: present(\.problem), presenting: model.problem) { _ in
            Button("OK") {}
        } message: { problem in
            Text(problem)
        }
        .onChange(of: model.renaming) { _, ref in
            draftName = ref?.name ?? ""
        }
        .onChange(of: model.askingPort) { _, asking in
            // The newest address on screen is the likeliest one wanted.
            if asking { draftPort = model.selectedTerminal?.screenPorts.last.map(String.init) ?? "" }
        }
        .onChange(of: model.hostID, initial: true) { _, host in
            ThemeStore.shared.chromeHost = host
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .overlay(alignment: .bottomTrailing) {
            if let probe = model.probe { ProbeLabel(probe: probe) }
        }
    }

    /// Presents a dialog while an optional model value is set, and clears it when the dialog closes.
    private func present<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } }
        )
    }

    /// Shown while a preview is open; closing the panel stops it.
    private var previewShown: Binding<Bool> {
        Binding(get: { model.preview != nil }, set: { if !$0 { model.closePreview() } })
    }

    private var fetchedShown: Binding<URL?> {
        Binding(get: { model.fetched }, set: { if $0 == nil { model.closeFetched() } })
    }
}

extension UTType {
    /// A session pill dragged onto the cards. It never leaves the app.
    static let lhunSession = UTType(exportedAs: "com.aktanazat.lhun.session")
}

extension SessionRef {
    /// What a pill or sidebar row carries when dragged onto the cards: the session's line, for this app
    /// alone.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(line.utf8)
        provider.registerDataRepresentation(for: .lhunSession, visibility: .ownProcess) { load in
            load(data, nil)
            return nil
        }
        return provider
    }
}

private struct DraggedSplit: Equatable {
    let path: [Int]
    let share: CGFloat
}

private struct DraggedCard {
    let ref: SessionRef
    let translation: CGSize
}

private struct CardArea: View {
    @Environment(AppModel.self) private var model
    @State private var dropHalf: Half?
    @State private var dropCovered: SessionRef?
    @GestureState private var dragShare: DraggedSplit?
    @GestureState private var floatingDrag: DraggedCard?
    @GestureState private var floatingResize: DraggedCard?
    @Environment(\.keyboardTravel) private var keyboard

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = model.compactLayout
            let gutter = CardSurface.gutter(compact: compact)
            let geometry = model.layout?.geometry(
                in: size, gutter: gutter, dragging: dragShare.map { ($0.path, $0.share) }
            ) ?? CardGeometry()
            let resting = keyboard.left == 0 ? geometry : model.layout?.geometry(
                in: CGSize(width: size.width, height: max(0, size.height - keyboard.left)), gutter: gutter,
                dragging: dragShare.map { ($0.path, $0.share) }
            ) ?? CardGeometry()
            ZStack(alignment: .topLeading) {
                if model.shownPanes.isEmpty {
                    Card(ref: nil, terminal: nil, split: false, focused: true, width: size.width, keyboard: KeyboardTravel())
                        .frame(width: size.width, height: size.height)
                }
                ForEach(model.shownCards, id: \.id) { card in
                    let ref = card.ref
                    let floating = model.floatingCards.first { $0.ref == ref }
                    let frame = model.zoomed == ref
                        ? CGRect(origin: .zero, size: size)
                        : floating.map { frame(for: $0, in: size) } ?? geometry.frame(for: ref) ?? .zero
                    let restingHeight = height(for: ref, floating: floating, in: size, resting: resting,
                                               keyboard: keyboard.left)
                    let move = floatingDrag?.ref == ref ? floatingDrag!.translation : .zero
                    let resize = floatingResize?.ref == ref ? floatingResize!.translation : .zero
                    Card(
                        ref: ref, terminal: model.terminals[ref], split: model.isSplit, focused: ref == model.selection,
                        width: frame.width + resize.width,
                        keyboard: KeyboardTravel(
                            left: frame.height - restingHeight,
                            heading: keyboard.heading, screenWidth: keyboard.screenWidth
                        )
                    )
                    .frame(width: max(0, frame.width + resize.width), height: max(0, frame.height + resize.height))
                    .overlay(alignment: .topLeading) {
                        if floating != nil, model.zoomed == nil {
                            floatingHandle(ref, size: size, resizing: false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if floating != nil, model.zoomed == nil {
                            floatingHandle(ref, size: size, resizing: true)
                        }
                    }
                    .offset(x: frame.minX + move.width, y: frame.minY + move.height)
                    .transition(.opacity)
                    .zIndex(floating == nil ? 0 : 2)
                }
                if model.zoomed == nil {
                    ForEach(geometry.splits) { split in
                        if compact {
                            CardDivider(across: split.stacked)
                                .frame(width: split.stacked ? split.area.width : nil,
                                       height: split.stacked ? nil : split.area.height)
                                .offset(x: split.stacked ? split.area.minX : split.first.maxX,
                                        y: split.stacked ? split.first.maxY : split.area.minY)
                                .zIndex(1)
                        }
                        gap(split, gutter: gutter)
                            .zIndex(1)
                    }
                }
            }
            .modifier(GridHold(arrangement: model.arrangement,
                               held: dragShare != nil || floatingDrag != nil || floatingResize != nil || model.keyboardAway))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if let dropHalf {
                    let target = dropCovered.flatMap {
                        dropTargetFrame($0, model: model, geometry: geometry, in: size)
                    } ?? CGRect(origin: .zero, size: size)
                    let zone = CardLayout(stacked: dropHalf.stacks, share: 0.5, gutter: gutter)
                        .zone(dropHalf, in: target.size).offsetBy(dx: target.minX, dy: target.minY)
                    DropZone(compact: compact)
                        .frame(width: zone.width, height: zone.height)
                        .offset(x: zone.minX, y: zone.minY)
                        .id(dropHalf)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: dropHalf)
                }
            }
            .onDrop(of: CardDrop.types, delegate: CardDrop(
                model: model, size: size, geometry: geometry, covered: $dropCovered, half: $dropHalf
            ))
        }
        .clipShape(Rectangle().inset(by: -CardSurface.gutter(compact: false))
            .offset(y: CardSurface.gutter(compact: false)))
    }

    private func frame(for card: FloatingCard, in size: CGSize) -> CGRect {
        CGRect(x: card.bounds.minX * size.width, y: card.bounds.minY * size.height,
               width: card.bounds.width * size.width, height: card.bounds.height * size.height)
    }

    private func height(for ref: SessionRef, floating: FloatingCard?, in size: CGSize,
                        resting: CardGeometry, keyboard: CGFloat) -> CGFloat {
        let available = CGSize(width: size.width, height: max(0, size.height - keyboard))
        if model.zoomed == ref { return available.height }
        if let floating { return frame(for: floating, in: available).height }
        return resting.frame(for: ref)?.height ?? size.height
    }

    private func floatingHandle(_ ref: SessionRef, size: CGSize, resizing: Bool) -> some View {
        Image(systemName: resizing ? "arrow.down.right.and.arrow.up.left" : "hand.draw")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityLabel(resizing ? "Resize Card" : "Move Card")
            .gesture(
                DragGesture(minimumDistance: 5)
                    .updating(resizing ? $floatingResize : $floatingDrag) { drag, current, _ in
                        current = DraggedCard(ref: ref, translation: drag.translation)
                    }
                    .onEnded { drag in
                        if resizing { model.resizeFloatingCard(ref, by: drag.translation, in: size) }
                        else { model.moveFloatingCard(ref, by: drag.translation, in: size) }
                    }
            )
    }

    private func gap(_ split: CardSplitFrame, gutter: CGFloat) -> some View {
        let reach: CGFloat = 10
        var grip = Path()
        if split.stacked {
            grip.addRect(CGRect(x: split.area.minX, y: split.first.maxY - reach,
                                width: split.area.width, height: split.second.minY - split.first.maxY + reach))
        } else {
            grip.addRect(CGRect(x: split.first.maxX, y: split.area.minY,
                                width: split.second.minX - split.first.maxX, height: split.area.height))
            grip.addRect(CGRect(x: split.first.maxX - reach, y: split.area.minY + CardHeader.height,
                                width: split.second.minX - split.first.maxX + 2 * reach,
                                height: max(split.area.height - CardHeader.height, 0)))
        }
        let bounds = grip.boundingRect
        let startingShare = model.layout?.share(at: split.path) ?? split.share
        let room = (split.stacked ? split.area.height : split.area.width) - gutter
        let moved = { (drag: DragGesture.Value) in
            guard room > 0 else { return startingShare }
            let distance = split.stacked ? drag.translation.height : drag.translation.width
            return CardShares.clamped(startingShare + distance / room)
        }
        return Color.clear
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(grip.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
            .offset(x: bounds.minX, y: bounds.minY)
            .gesture(
                DragGesture()
                    .updating($dragShare) { drag, share, _ in share = DraggedSplit(path: split.path, share: moved(drag)) }
                    .onEnded { drag in model.resize(splitAt: split.path, to: moved(drag)) }
            )
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityValue("\(Int((split.share * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.resize(splitAt: split.path, to: split.share + 0.05)
                case .decrement: model.resize(splitAt: split.path, to: split.share - 0.05)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(split.path.isEmpty ? "gap" : "gap.\(split.id)")
    }
}

/// Keeps the cards clear of the on-screen keyboard, moving with it frame for frame (`KeyboardMotion`) in
/// place of SwiftUI's own keyboard room, and passes on what is left of its move (`KeyboardTravel`), so each
/// terminal can fit its grid to where its card comes to rest.
private struct KeyboardRoom: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let motion = model.keyboardMotion
        content
            .padding(.bottom, motion.inset)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environment(\.keyboardTravel, KeyboardTravel(
                left: motion.heading - motion.inset, heading: motion.heading, screenWidth: motion.screenWidth
            ))
    }
}

extension EnvironmentValues {
    /// The terminals keep their grids for now (`GridHold`).
    @Entry var holdsGrid = false
    /// What is left of the keyboard's move for the cards' area.
    @Entry var keyboardTravel = KeyboardTravel()
}

/// Makes the terminals on the cards keep their grids while the cards move, the gutter is dragged, or the
/// keyboard is away with the palette, a picker or the inbox (`AppModel.keyboardAway`), so each fits once
/// they rest and tmux sees one size change instead of one per frame. A move is over once
/// `AppModel.arrangement`, which rides the move's own animation, has arrived here. A completion on that
/// animation's transaction would wait for everything else the move sets going too, and one of those can
/// go unreported: a card's header swapping its folder line for a shorter one as the card narrowed once
/// left every grid held for good.
private struct GridHold: ViewModifier, Animatable {
    /// `arrangement` as far as the move has carried it.
    var carried: Double
    let arrangement: Double
    /// The gutter is dragged or the keyboard is away.
    let held: Bool

    init(arrangement: Int, held: Bool) {
        carried = Double(arrangement)
        self.arrangement = Double(arrangement)
        self.held = held
    }

    nonisolated var animatableData: Double {
        get { carried }
        set { carried = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.holdsGrid, held || carried != arrangement)
    }
}

/// One session's terminal on a rounded card under its header, or what to know while none is open. Beside
/// another card its terminal dims a little while the other card has the focus; its header stays readable.
private struct Card: View {
    let ref: SessionRef?
    let terminal: TerminalModel?
    /// Beside another card, or zoomed over it.
    let split: Bool
    /// Takes the typing. Beside another card, the one without the focus dims its terminal.
    let focused: Bool
    /// True while the cards move, the gutter is dragged, or the keyboard is away (`GridHold`): the terminal
    /// keeps its grid until they rest.
    @Environment(\.holdsGrid) private var holdsGrid
    /// The card's width, which decides how many glyphs its header shows.
    let width: CGFloat
    /// What is left of the keyboard's move for this card.
    let keyboard: KeyboardTravel
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dimmed = split && !focused
        let dark = colorScheme == .dark
        // Each host's sessions keep its look wherever they show.
        let chrome = ref.map { ThemeStore.shared.chrome(for: $0.host) } ?? ThemeStore.shared.chrome
        VStack(spacing: 0) {
            if let ref {
                CardHeader(ref: ref, split: split, focused: focused, width: width)
            }
            Group {
                if let terminal {
                    TerminalScreen(
                        terminal: terminal, palette: ThemeStore.shared.palette(for: terminal.ref.host, dark: dark),
                        fontSize: model.fontSize, face: model.terminalFont, focused: focused, dimmed: dimmed,
                        holdsGrid: holdsGrid, keyboard: keyboard, showsKeyboard: !model.peek.isShown,
                        askAkyl: model.canAskAkyl ? { [ref = terminal.ref] in model.askAkyl(about: ref, selection: $0) } : nil,
                        onStepWindow: { model.stepWindow($0) }
                    ) { size in
                        model.setFontSize(size)
                    }
                    .overlay(alignment: .top) {
                        if terminal.state != .live, model.tailscaleStalled {
                            StallNotice()
                        } else {
                            CardStatus(text: status(of: terminal))
                        }
                    }
                } else {
                    EmptyCard()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // The first touch on the other card only gives it the focus.
                if dimmed, let ref {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { model.focusCard(ref) }
                }
            }
        }
        .modifier(CardSurface(
            compact: model.compactLayout, dimmed: dimmed, header: ref == nil ? 0 : CardHeader.height, chrome: chrome
        ))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            // Where a kill's fade lays the card's last picture.
            if let ref { model.fade.frames[ref] = frame }
        }
        .onChange(of: ref) { left, shown in
            // The card stays where it was, showing another session now.
            guard let left, let shown else { return }
            model.fade.frames[shown] = model.fade.frames.removeValue(forKey: left)
        }
        .onDisappear {
            if let ref { model.fade.frames[ref] = nil }
        }
    }

    private func status(of terminal: TerminalModel) -> String? {
        switch terminal.state {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .live: terminal.uploads > 0 ? "Uploading…" : nil
        }
    }
}

/// What a card is waiting on, over the top of its terminal: connecting, reconnecting, uploading. A wait that
/// ends within half a second shows nothing, so a session that attaches at once or a connection that comes
/// straight back never flashes a label; a longer one fades the label in, and out as it ends. While it waits
/// unseen, the label is already there for VoiceOver and for a test waiting for the session to attach.
private struct CardStatus: View {
    let text: String?
    @State private var shows = false

    var body: some View {
        ZStack {
            if let text {
                // Only the colors fade in: a view at no opacity at all can drop out of the accessibility tree.
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(HierarchicalShapeStyle.secondary.opacity(shows ? 1 : 0))
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.near)
                    .background {
                        Capsule().fill(.thickMaterial).opacity(shows ? 1 : 0)
                    }
                    .padding(.top, Metrics.near)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .accessibilityIdentifier("status")
            }
        }
        .animation(.easeOut(duration: 0.2), value: shows)
        .animation(.easeOut(duration: 0.2), value: text == nil)
        .task(id: text == nil) {
            shows = false
            guard text != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { shows = true }
        }
    }
}

/// Over a card that cannot attach while no host answers (`AppModel.tailscaleStalled`).
private struct StallNotice: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(Stall.message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("status")
            OpenTailscale()
                .font(.footnote.weight(.semibold))
                .frame(minHeight: Metrics.touch)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.top, Metrics.near)
        .background(.thickMaterial, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .padding([.top, .horizontal], Metrics.near)
        .transition(.opacity)
    }
}

private enum Stall {
    static let message = "Neither \(Host.mac.phrase) nor \(Host.server.phrase) answers. Turn Tailscale off and on."
    static let tailscale = URL(string: "tailscale://")!
}

/// Tailscale's own app, where he turns it off and on.
private struct OpenTailscale: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Tailscale") { openURL(Stall.tailscale) }
    }
}

/// A card's header: what its active pane runs, its name and where. The focused card's shows glyphs on the
/// right that split it right or down, zoom it while two are open, and close it, as many as leave its name
/// room. A tap gives the card the focus; a double tap zooms it to the whole area and back.
struct CardHeader: View {
    let ref: SessionRef
    /// Beside another card, or zoomed over it: zoom is offered.
    let split: Bool
    /// The glyphs show only on the focused card.
    let focused: Bool
    /// The card's width, which decides how many glyphs fit.
    let width: CGFloat
    @Environment(AppModel.self) private var model

    /// Tall enough for each glyph's 44-point target. Taps that land below it go to the terminal, which UIKit
    /// hit-tests ahead of any SwiftUI view reaching over it.
    static let height: CGFloat = 44
    /// The program's mark beside the name, at the usual text size.
    static let mark: CGFloat = 16

    /// What a glyph in the header does.
    enum Glyph {
        case splitRight, splitDown, zoom, float, close
    }

    /// Fewer controls fit when a card is narrow; the palette exposes each action.
    static func glyphs(split: Bool, width: CGFloat) -> [Glyph] {
        let all: [Glyph] = split
            ? [.splitRight, .splitDown, .zoom, .float, .close]
            : [.splitRight, .splitDown, .float, .close]
        let fixed = Metrics.inset + mark + 4 * Metrics.near
        let fit = Int(((width - fixed - 60) / height).rounded(.down))
        return Array(all.suffix(min(max(fit, 0), all.count)))
    }

    var body: some View {
        let session = model.link(for: ref)?.sessions.first { $0.name == ref.name }
        let zoomed = model.zoomed == ref
        let glyphs = Self.glyphs(split: split, width: width)
        let id = "card.\(ref.host).\(ref.name)"
        HStack(spacing: Metrics.near) {
            if let session {
                HeaderMark(session: session)
            }
            Text(ref.name)
                .font(.footnote.weight(.semibold))
                .probeFrame("\(id).name")
                // The program and folder give way first.
                .layoutPriority(1)
            if let session {
                SessionDetail(name: session.name, lead: session.command, folder: session.folder)
                    .font(.footnote)
                    .foregroundStyle(ThemeStore.shared.chrome(for: ref.host).detail)
            }
            Spacer(minLength: Metrics.near)
        }
        .lineLimit(1)
        .padding(.leading, Metrics.inset)
        // The glyphs lie over this end. The name gives way to them even while they are hidden, so it never
        // shifts as the focus moves.
        .padding(.trailing, CGFloat(glyphs.count) * CardHeader.height)
        .frame(height: Self.height)
        .contentShape(.rect)
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture())
                .onEnded { tap in
                    switch tap {
                    case .first: model.toggleZoom(ref)
                    case .second: model.focusCard(ref)
                    }
                }
        )
        // Over the header's tap shape, so a tap on a glyph never also focuses or zooms through the header.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                ForEach(glyphs, id: \.self) { glyph in
                    switch glyph {
                    case .splitRight:
                        HeaderGlyph(id: "splitRight", symbol: "rectangle.split.2x1", label: "Split Right") { model.split(.right) }
                    case .splitDown:
                        HeaderGlyph(id: "splitDown", symbol: "rectangle.split.1x2", label: "Split Down") { model.split(.bottom) }
                    case .zoom:
                        HeaderGlyph(
                            id: "zoom",
                            symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: zoomed ? "Restore Cards" : "Zoom Card"
                        ) { model.toggleZoom(ref) }
                    case .float:
                        HeaderGlyph(
                            id: "float", symbol: model.isFloating(ref) ? "rectangle.inset.filled" : "macwindow",
                            label: model.isFloating(ref) ? "Tile Card" : "Float Card"
                        ) { model.toggleFloatingCard(ref) }
                    case .close:
                        HeaderGlyph(id: "close", symbol: "xmark", label: "Close Card") { model.detach(ref) }
                    }
                }
            }
            .probeFrame("\(id).glyphs")
            .opacity(focused ? 1 : 0)
            .allowsHitTesting(focused)
            .accessibilityHidden(!focused)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        // A bar of fixed height: its text stops growing short of the accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .probeFrame(id)
    }
}

/// A glyph in a card's header, its target the header's full 44 points square.
private struct HeaderGlyph: View {
    let id: String
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(width: CardHeader.height, height: CardHeader.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .accessibilityIdentifier("card.\(id)")
    }
}

/// The program's mark beside a card's name, grown and shrunk with the name's text.
private struct HeaderMark: View {
    let session: TmuxSession
    @ScaledMetric(relativeTo: .footnote) private var side = CardHeader.mark

    var body: some View {
        ProgramIconView(command: session.command, model: session.model, size: side)
    }
}

/// Where a dragged pill would open: the half of the area it is nearest, or all of it while no card is open.
private struct DropZone: View {
    let compact: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CardSurface.radius(compact: compact), style: .continuous)
            .fill(Color.primary.opacity(0.12))
            .allowsHitTesting(false)
    }
}

@MainActor
private func dropTargetFrame(_ ref: SessionRef, model: AppModel, geometry: CardGeometry,
                             in size: CGSize) -> CGRect? {
    if model.zoomed == ref { return CGRect(origin: .zero, size: size) }
    if let card = model.floatingCards.first(where: { $0.ref == ref }) {
        return CGRect(x: card.bounds.minX * size.width, y: card.bounds.minY * size.height,
                      width: card.bounds.width * size.width, height: card.bounds.height * size.height)
    }
    return geometry.frame(for: ref)
}

private struct CardDrop: DropDelegate {
    static let types = TerminalDrop.types + [.data]

    let model: AppModel
    let size: CGSize
    let geometry: CardGeometry
    @Binding var covered: SessionRef?
    @Binding var half: Half?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: isTerminal(info) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        half = nil
        covered = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = card(at: info.location)
        let area = target.flatMap {
            dropTargetFrame($0, model: model, geometry: geometry, in: size)
        } ?? CGRect(origin: .zero, size: size)
        let side = Half(nearest: CGPoint(x: info.location.x - area.minX, y: info.location.y - area.minY),
                        in: area.size)
        half = nil
        covered = nil
        if let drop = TerminalDrop(providers: info.itemProviders(for: TerminalDrop.types)) {
            Task { @MainActor [model] in
                guard let destination = await drop.target() else { return }
                switch destination {
                case .pane(let pane):
                    model.open(pane.ref, on: side, over: target)
                    model.focusPane(pane)
                case .session(let ref):
                    model.open(ref, on: side, over: target)
                }
            }
            return true
        }
        guard let target, let terminal = model.terminals[target] else { return false }
        model.upload(info.itemProviders(for: [.data]), into: terminal)
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard isTerminal(info) else {
            half = nil
            covered = nil
            return
        }
        covered = card(at: info.location)
        let area = covered.flatMap {
            dropTargetFrame($0, model: model, geometry: geometry, in: size)
        } ?? CGRect(origin: .zero, size: size)
        half = Half(nearest: CGPoint(x: info.location.x - area.minX, y: info.location.y - area.minY),
                    in: area.size)
    }

    private func card(at point: CGPoint) -> SessionRef? {
        if let zoomed = model.zoomed { return zoomed }
        for card in model.floatingCards.reversed() {
            let bounds = CGRect(x: card.bounds.minX * size.width, y: card.bounds.minY * size.height,
                                width: card.bounds.width * size.width, height: card.bounds.height * size.height)
            if bounds.contains(point) { return card.ref }
        }
        return geometry.ref(at: point)
    }

    private func isTerminal(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: TerminalDrop.types)
    }
}

/// What to know about the chosen host while no session is open.
private struct EmptyCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Metrics.apart) {
            Text(message)
                .font(.callout)
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
            if model.key != nil && (model.currentLink == nil || model.currentLink?.status == .keyNotAccepted) {
                Button("Pair a Mac or Server") { model.showingKey = true }
                    .buttonStyle(.borderedProminent)
                    // The accent is ink, near white in dark, so the label takes the background's color.
                    .foregroundStyle(Color(uiColor: .systemBackground))
            } else if stalled {
                OpenTailscale()
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
        }
        .padding(Metrics.section)
        .frame(maxWidth: 420)
    }

    /// The current host is out of reach along with every other one.
    private var stalled: Bool {
        model.currentLink?.status == .unreachable && model.tailscaleStalled
    }

    private var message: String {
        if let problem = model.keyProblem { return problem }
        if stalled { return Stall.message }
        guard let link = model.currentLink else { return "No hosts paired." }
        let phrase = link.host.phrase
        switch link.status {
        case .connecting: return "Connecting to \(phrase)…"
        case .online where link.sessions.isEmpty: return "No sessions on \(phrase). Press + to start one."
        case .online where model.sidebar.replacesStrip:
            return model.sidebar.isOn ? "Pick a session on the left, or press ⌘K." : "Pick a session in the sidebar, or press ⌘K."
        case .online: return "Pick a session above, or press ⌘K."
        case .unreachable: return "Can't reach \(phrase). Check that Tailscale is on."
        case .keyNotAccepted: return "\(capitalized(phrase)) doesn't know this \(UIDevice.current.localizedModel)'s key yet."
        case .hostKeyChanged: return "\(capitalized(phrase)) is answering with a different identity, so Lhûn won't connect."
        }
    }

    /// What he has to set right reads in the primary ink: a key the host turned down, an identity that
    /// changed, a problem with this device's key, Tailscale carrying nothing. Anything Lhûn is waiting on,
    /// the network too, reads in the secondary.
    private var ink: HierarchicalShapeStyle {
        switch model.currentLink?.status {
        case .keyNotAccepted, .hostKeyChanged: .primary
        case .unreachable where model.tailscaleStalled: .primary
        default: model.keyProblem == nil ? .secondary : .primary
        }
    }

    private func capitalized(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst()
    }
}

/// A note at the foot of the screen that comes and goes by itself, over whatever is there.
private struct NoticeLabel: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.footnote)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.near)
                    .background(.thickMaterial, in: .capsule)
                    .padding(.bottom, Metrics.inset)
                    .transition(.opacity)
                    .accessibilityIdentifier("notice")
            }
        }
        .animation(.easeOut(duration: 0.2), value: text)
        .allowsHitTesting(false)
    }
}

/// The probe's latest sample, readable by the UI test and invisible on screen.
private struct ProbeLabel: View {
    let probe: Probe

    var body: some View {
        Text(probe.latest)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("probe")
    }
}
