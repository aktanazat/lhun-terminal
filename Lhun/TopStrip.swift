import SwiftUI

/// The strip above the cards: which host, its sessions as pills, the inbox's tray while something waits,
/// and two glyphs for everything else.
struct TopStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hidden = HiddenEnds()
    /// How wide the part of the strip the pills scroll in is. No pill is wider, so the open one shows whole.
    @State private var room = SessionPill.widest

    var body: some View {
        HStack(spacing: Metrics.near) {
            // The host's name and status keep their whole width; in a narrow window the pills' scroller,
            // which scrolls, gives up the room.
            HostChip()
                .probeFrame("host")
                .layoutPriority(1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.near) {
                        if let link = model.currentLink {
                            ForEach(model.tabSessions(on: link)) { session in
                                SessionPill(link: link, session: session, room: room)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .probeFrame("pills")
                .onScrollGeometryChange(for: HiddenEnds.self) { geometry in
                    HiddenEnds(
                        leading: geometry.visibleRect.minX > 0.5,
                        trailing: geometry.visibleRect.maxX < geometry.contentSize.width - 0.5
                    )
                } action: { _, ends in
                    hidden = ends
                }
                .mask { EdgeFade(hidden: hidden, room: room) }
                // The open session's pill stays in view: when it opens from the keys, the palette or the
                // pictures, when its pill first arrives, and when the strip changes width, as the screen turns
                // or the window is sized.
                .onChange(of: openPill, initial: true) { follow(proxy, animated: true) }
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
                    room = width
                    follow(proxy, animated: false)
                }
            }
            // The glyphs at the end share one size, the inbox's tray among them.
            if model.sidebar.fits { SessionLayoutButton() }
            HStack(spacing: Metrics.near) {
                InboxGlyph()
                Glyph(symbol: "command", label: "Commands") { model.showingPalette = true }
                    .accessibilityIdentifier("palette")
                    .probeFrame("palette")
                Glyph(symbol: "plus", label: "New Session") { model.newSession(on: model.currentLink) }
                    .accessibilityIdentifier("new-session")
                    .disabled(model.currentLink?.status != .online)
                    .probeFrame("new-session")
            }
            .font(.callout)
        }
        .padding(.leading, Metrics.inset)
        // Less at the trailing end: the glyphs' 44-point squares already hold room around their symbols.
        .padding(.trailing, Metrics.near)
        // Clear of the window's controls, which sit at its top left while it is short of the screen.
        .containerCornerOffset(.leading, sizeToFit: true)
        // A pill's face with room above and below it.
        .frame(height: PillFace.height + 2 * Metrics.near)
        // The bar keeps its height, so its words stop growing at the largest size it holds.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip")
    }

    /// The open session's name while its pill is in the strip.
    private var openPill: String? {
        guard let selection = model.selection, let link = model.currentLink else { return nil }
        let root = model.tabRoot(for: selection)
        guard root.host == link.host.id, model.tabSessions(on: link).contains(where: { $0.name == root.name })
        else { return nil }
        return root.name
    }

    /// Scrolls just far enough to show the open session's pill whole, and not at all while it is.
    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let name = openPill else { return }
        withAnimation(animated && !reduceMotion ? .smooth : nil) { proxy.scrollTo(name) }
    }
}

/// Which ends of the strip have pills scrolled past them.
private struct HiddenEnds: Equatable {
    var leading = false
    var trailing = false
}

/// Fades the pills out at an end with more of them past it, so a pill cut by the edge reads as the strip
/// going on rather than as a pill sliced under the host or the glyphs. An end with nothing past it stays
/// sharp.
private struct EdgeFade: View {
    let hidden: HiddenEnds
    /// How wide the part of the strip the pills scroll in is.
    let room: CGFloat

    /// Wide enough that a sliver of a pill left at an end all but vanishes, and a longer piece clearly fades;
    /// in a narrow strip an eighth of it, so the fade stays in the margin of a pill as wide as the strip.
    private var width: CGFloat { min(40, room / 8) }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.opacity(hidden.leading ? 0 : 1)
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: width)
            Color.black
            ZStack {
                Color.black.opacity(hidden.trailing ? 0 : 1)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: width)
        }
        .animation(.easeOut(duration: 0.15), value: hidden)
    }
}

/// The chosen host, and a menu to switch to the other one. Under the name, a word on how the host is doing
/// while it is not online; online is the normal state, so it goes unsaid.
private struct HostChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let status = model.currentLink?.status
        Menu {
            ForEach(model.links) { link in
                Button(link.host.name, systemImage: link.host.symbol) { model.switchHost(to: link) }
            }
            if model.links.isEmpty {
                Button("Pair a Mac or Server") { model.showingKey = true }
            }
        } label: {
            HStack(spacing: Metrics.near) {
                Image(systemName: model.currentLink?.host.symbol ?? "questionmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if sizeClass != .compact {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.currentLink?.host.name ?? "Lhûn")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        if status != .online {
                            Text(status?.label ?? "not paired")
                                .font(.footnote)
                                .foregroundStyle(Theme.detail)
                        }
                    }
                }
            }
            .frame(minWidth: sizeClass == .compact ? Metrics.touch : nil, minHeight: Metrics.touch)
            .contentShape(.rect)
        }
        .accessibilityLabel(
            [model.currentLink?.host.name ?? "Lhûn", status == .online ? "" : status?.label ?? "not paired"]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityIdentifier("host")
    }
}

extension Host {
    /// A laptop for the Mac, a rack for the server, by its name in the strip and the sidebar.
    var symbol: String {
        id == "mac" ? "laptopcomputer" : "server.rack"
    }
}

extension HostLink.Status {
    /// A word or two for how the host is doing, under its name in the strip and beside it in the sidebar,
    /// both only while it is not online.
    var label: String {
        switch self {
        case .online: "online"
        case .connecting: "connecting"
        case .unreachable: "unreachable"
        case .keyNotAccepted: "key not accepted"
        case .hostKeyChanged: "identity changed"
        }
    }
}

private struct SessionPill: View {
    let link: HostLink
    let session: TmuxSession
    let room: CGFloat
    @Environment(AppModel.self) private var model
    @State private var pointed = false

    static let widest: CGFloat = 320
    static let icon: CGFloat = 16

    var body: some View {
        let ref = SessionRef(host: link.host.id, name: session.name)
        let members = model.tabMembers(ref)
        let isOpen = model.selection.map { model.tabRoot(for: $0) == ref } ?? false
        let attention = model.tabAttention(ref)
        let mark = attention?.mark
        let activitySession = attention?.session ?? session
        let doing = attention?.doing ?? session.task ?? session.command
        let closes = pointed
        let background = isOpen ? Theme.raised : Theme.pill
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Button {
                    model.selectTab(ref)
                } label: {
                    HStack(spacing: 0) {
                        TabProgramMarks(ref: ref, size: Self.icon, background: background)
                            .opacity(closes ? 0 : 1)
                            .frame(width: Metrics.touch)
                        GivesWay(least: 24) {
                            HStack(spacing: 0) {
                                Text(session.name)
                                    .fontWeight(isOpen ? .semibold : .regular)
                                    .foregroundStyle(isOpen ? Color.primary : Theme.detail)
                                if session.windows > 1 {
                                    Text(":\(session.window)")
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.detail)
                                        .fixedSize()
                                }
                            }
                        }
                        .layoutPriority(1)
                        SessionDetail(
                            name: session.name, lead: doing,
                            folder: activitySession.folder, gap: Metrics.near
                        )
                        .foregroundStyle(Theme.detail)
                        if let mark {
                            AttentionMark(mark: mark)
                                .padding(.leading, Metrics.near)
                        }
                    }
                    .font(.footnote)
                    .lineLimit(1)
                    .padding(.trailing, Metrics.near)
                    .frame(maxWidth: max(0, min(Self.widest, room) - Metrics.touch), alignment: .leading)
                    .frame(height: PillFace.height)
                    .padding(.vertical, Metrics.near)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session.\(link.host.id).\(session.name)")
                .accessibilityLabel(
                    [title, [doing, activitySession.folder].filter { !$0.isEmpty }.joined(separator: " "),
                     members.count > 1 ? "\(members.count) terminals" : ""]
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                )
                .accessibilityValue(AttentionMark.label(mark, status: attention?.status))
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                .contentShape([.contextMenuPreview, .dragPreview], PillFace())
                .contextMenu {
                    if model.canAskAkyl {
                        Button("Ask Akyl", systemImage: "bubble.left") { model.askAkyl(about: ref) }
                    }
                    Button("Close Tab", systemImage: "xmark") { model.detachTab(ref) }
                    Button("Rename…", systemImage: "pencil") { model.renaming = ref }
                    Button("Kill Session", systemImage: "xmark", role: .destructive) { model.killing = ref }
                }
                .onDrag { ref.itemProvider() } preview: {
                    PillLift(session: session, name: title, width: min(Self.widest, room))
                }
                if closes {
                    Button("Close \(session.name)", systemImage: "xmark") { model.killTab(ref) }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.touch, height: Metrics.touch)
                        .contentShape(.rect)
                        .contentShape(.hoverEffect, .circle.inset(by: Metrics.tight))
                        .hoverEffect(.highlight)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session.close.\(link.host.id).\(session.name)")
                }
            }
            TabActivityButton(
                ref: ref, arrowEdge: .top,
                identifier: "session.more.\(link.host.id).\(session.name)"
            )
        }
        .frame(maxWidth: min(Self.widest, room))
        .background(background, in: PillFace())
        .probeFrame("pill.\(link.host.id).\(session.name)")
        .hoverPicture(ref, place: .below)
        .onPointer(over: ref) { pointed = $0 }
    }

    private var title: String {
        session.windows > 1 ? "\(session.name):\(session.window)" : session.name
    }
}

/// A pill's face, centered in whatever holds it: the shape the pill is drawn in, and the one its menu and a
/// drag lift from its taller touch area.
private struct PillFace: Shape {
    /// A line of the strip's text with room around it, short of the strip's height.
    static let height: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect.insetBy(dx: 0, dy: max((rect.height - Self.height) / 2, 0)),
            cornerRadius: Metrics.radius, style: .continuous
        )
    }
}

/// A pill as a drag lifts it: its icon and name on the raised face of an open session's pill, the name in
/// full ink. The system draws what is dragged a little see-through over the cards, which took the softer name
/// of a pill not on screen below 4.5:1 there.
private struct PillLift: View {
    let session: TmuxSession
    /// The session's name, with its window's number when it has more than one.
    let name: String
    let width: CGFloat

    var body: some View {
        let face = PillFace()
        HStack(spacing: Metrics.near) {
            ProgramIconView(command: session.command, model: session.model, size: SessionPill.icon)
            Text(name)
                .font(.footnote)
                .foregroundStyle(Color.primary)
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.near)
        .frame(maxWidth: width)
        .frame(height: PillFace.height)
        .background(Theme.raised, in: face)
        .contentShape(.dragPreview, face)
    }
}

/// Its content whole where that fits, cut short where at least `least` points are left for it, and otherwise
/// left out with the gap before it, rather than cut to a sliver of a letter.
private struct GivesWay<Content: View>: View {
    let least: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.padding(.leading, Metrics.near)
            content.frame(minWidth: least, idealWidth: least, alignment: .leading).padding(.leading, Metrics.near)
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// The gray words after a session's name: what it runs, or the task it reports, then its folder. The whole
/// folder where that fits, else only the folder's own name, else what it runs alone, cut at its end where at
/// least 40 points are left, so the folder is never cut short; else nothing, with the `gap` before it. With
/// nothing to lead, the folder's own name is what is cut. A folder's own name that is the session's name
/// says nothing the name beside it does not, so it is left out.
struct SessionDetail: View {
    /// The session's name, which stands just before.
    let name: String
    let lead: String
    let folder: String
    var gap: CGFloat = 0

    var body: some View {
        let own = (folder as NSString).lastPathComponent
        let short = own == name ? "" : own
        ViewThatFits(in: .horizontal) {
            line(folder).padding(.leading, gap)
            line(short).padding(.leading, gap)
            line(lead.isEmpty ? short : "")
                .frame(minWidth: 40, idealWidth: 40, alignment: .leading)
                .padding(.leading, gap)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func line(_ place: String) -> some View {
        Text([lead, place].filter { !$0.isEmpty }.joined(separator: " "))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A quiet icon button, a full 44 points square to touch, its symbol in the font around it.
private struct Glyph: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.touch, height: Metrics.touch)
            .contentShape(.rect)
            .buttonStyle(.plain)
    }
}
