import SwiftUI

/// How the sessions are laid out: pills along the top, or, while the iPad is held sideways, a sidebar left
/// of the cards listing every host's sessions, as Rex does. Held upright, the sidebar layout shows the pills
/// instead: the cards need the width. Tabs until he picks.
enum SessionLayout: String, CaseIterable, Sendable {
    case tabs
    case sidebar

    var title: String {
        switch self {
        case .tabs: "Tabs"
        case .sidebar: "Sidebar"
        }
    }
}

struct SessionLayoutButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sidebar = model.sidebar.layout == .sidebar
        Button(sidebar ? "Show Tabs" : "Show Sidebar", systemImage: sidebar ? "rectangle.topthird.inset.filled" : "sidebar.left") {
            model.switchLayout()
            if model.sidebar.layout == .sidebar, !model.sidebar.isOn {
                model.toggleSidebar(animated: false)
            }
        }
        .labelStyle(.iconOnly)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: Metrics.touch, height: Metrics.touch)
        .contentShape(.rect)
        .contentShape(.hoverEffect, .circle)
        .hoverEffect(.highlight)
        .buttonStyle(.plain)
        .accessibilityIdentifier("layout-toggle")
    }
}

/// The layout he picked, whether he has the sidebar out and which of its groups he folded, all kept across
/// launches, and whether the window is wide enough for it.
@MainActor @Observable
final class SessionSidebar {
    static let width: CGFloat = 280
    /// The narrowest window with room for it beside the cards: the iPad held sideways, never upright.
    static let minimumWindowWidth: CGFloat = 1100
    private static let layoutKey = "layout"
    private static let shownKey = "sidebar"
    private static let foldedKey = "sidebarFolded"
    private static let activityKey = "sidebarActivity"

    /// For the probe: the rows drawn, 0 while the sidebar is hidden.
    static var rows = 0
    /// For the probe: the folds since launch that slid, and those that happened at once, with Reduce Motion
    /// on.
    static var folds = ["animated": 0, "still": 0]

    private(set) var layout: SessionLayout
    /// He has the sidebar out, in the sidebar layout.
    private(set) var isOn: Bool
    /// The groups he folded: a host by its id, a folder as "<host>/<folder>".
    private(set) var folded: Set<String>
    /// The list shows only the sessions with activity (SidebarActivity), rather than every host's.
    private(set) var showsActivity: Bool
    /// The window is wide enough for the sidebar. The layout that places it says so.
    fileprivate(set) var fits = false
    /// The filter holds the keys.
    fileprivate(set) var filtering = false

    init() {
        let defaults = LhunDefaults.shared
        layout = defaults.string(forKey: Self.layoutKey).flatMap(SessionLayout.init(rawValue:)) ?? .tabs
        // bool(forKey:) also reads a launch argument such as `-sidebar NO`.
        isOn = defaults.object(forKey: Self.shownKey) == nil || defaults.bool(forKey: Self.shownKey)
        // Also a launch argument, such as `-sidebarFolded '()'`.
        folded = Set(defaults.stringArray(forKey: Self.foldedKey) ?? [])
        // Also a launch argument: `-sidebarActivity YES`.
        showsActivity = defaults.bool(forKey: Self.activityKey)
    }

    /// The sidebar, or the bar that brings it back, stands where the strip would.
    var replacesStrip: Bool {
        layout == .sidebar && fits
    }

    /// The list is out, narrowed to the sessions with activity.
    var showingActivity: Bool {
        isOn && showsActivity
    }

    fileprivate func toggle() {
        isOn.toggle()
        if !isOn { filtering = false }
        LhunDefaults.shared.set(isOn, forKey: Self.shownKey)
    }

    fileprivate func showActivity(_ shown: Bool) {
        showsActivity = shown
        LhunDefaults.shared.set(shown, forKey: Self.activityKey)
    }

    /// Folds the group away, or opens it again. With Reduce Motion on, its rows go and come at once.
    fileprivate func fold(_ group: String, animated: Bool) {
        Self.folds[animated ? "animated" : "still", default: 0] += 1
        withAnimation(animated ? .smooth(duration: 0.25) : nil) {
            if folded.remove(group) == nil { folded.insert(group) }
        }
        LhunDefaults.shared.set(folded.sorted(), forKey: Self.foldedKey)
    }

    /// The next layout, from the palette's settings row; after the last comes the first.
    fileprivate func switchLayout() {
        let all = SessionLayout.allCases
        layout = all.drop { $0 != layout }.dropFirst().first ?? all[0]
        LhunDefaults.shared.set(layout.rawValue, forKey: Self.layoutKey)
    }
}

extension AppModel {
    /// Shows or hides the sidebar. The cards make room in one slide and each terminal fits once it ends,
    /// so tmux sees one size change. From the palette it switches at once instead, as the compact layout
    /// does: the palette's closing moves the on-screen keyboard at the same moment.
    func toggleSidebar(animated: Bool = true) {
        guard sidebar.replacesStrip else { return }
        // The keys go back to the terminal if the filter had them, and only then: with no keyboard
        // attached, focusing the terminal raises the on-screen one, and the cards would shrink twice.
        let refocus = sidebar.isOn && sidebar.filtering
        if animated {
            arrange { sidebar.toggle() }
        } else {
            sidebar.toggle()
        }
        if refocus { focusTerminal() }
    }

    /// Narrows the list to the sessions with activity, or shows every session again. With the sidebar
    /// hidden, it comes out narrowed.
    func toggleActivity(animated: Bool = true) {
        guard sidebar.replacesStrip else { return }
        guard sidebar.isOn else {
            sidebar.showActivity(true)
            toggleSidebar(animated: animated)
            return
        }
        sidebar.showActivity(!sidebar.showsActivity)
    }

    /// Tabs or the sidebar, from the palette's settings. It switches at once, as the compact layout does.
    func switchLayout() {
        sidebar.switchLayout()
    }
}

/// What sits around the cards: the strip above them, or, in the sidebar layout while the window is wide
/// enough, the sidebar's bar at the top left and the list below it, left of the cards. Hidden, the list
/// slides away and the cards take its room and go under the bar, which stays where it was. Settled in the
/// pass that lays out the cards, so turning the iPad or showing the sidebar sizes each terminal once.
struct SessionChrome<Cards: View>: View {
    @Environment(AppModel.self) private var model
    private let cards: Cards

    init(@ViewBuilder cards: () -> Cards) {
        self.cards = cards()
    }

    var body: some View {
        GeometryReader { proxy in
            let fits = proxy.size.width >= SessionSidebar.minimumWindowWidth
            let replacesStrip = fits && model.sidebar.layout == .sidebar
            let shown = replacesStrip && model.sidebar.isOn
            let gutter = CardSurface.gutter(compact: model.compactLayout)
            // The bar sits where a card's header does, so its glyphs are level with the header beside them.
            let bar = gutter + CardHeader.height
            // With the list out, the cards reach the top, right of the bar; with it away, they sit under it.
            let top = !replacesStrip ? 0 : shown ? gutter : bar
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if shown {
                        SessionList()
                            .padding(.top, bar)
                            .frame(width: SessionSidebar.width)
                            .transition(.move(edge: .leading))
                    }
                    VStack(spacing: 0) {
                        if !replacesStrip {
                            TopStrip()
                                .contentShape(.rect)
                                .gesture(PeekPull(model: model))
                        }
                        cards
                            .padding(.top, top)
                    }
                }
                // One bar for both: its glyphs never move or blink as the list comes and goes.
                if replacesStrip {
                    SidebarBar()
                        .frame(width: SessionSidebar.width)
                        .padding(.top, gutter)
                }
            }
            .onChange(of: fits, initial: true) { model.sidebar.fits = fits }
        }
    }
}

/// The sidebar's top, as Rex has it: the sidebar's own glyph on the left, then the activity filter, all
/// sessions at a glance, the inbox's tray as the strip has it, the palette and a new session.
private struct SidebarBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            BarGlyph(symbol: "sidebar.left", label: model.sidebar.isOn ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .accessibilityIdentifier("sidebar-toggle")
            .accessibilityAddTraits(model.sidebar.isOn ? .isSelected : [])
            Spacer(minLength: 0)
            ActivityGlyph()
            BarGlyph(symbol: "eye", label: "Show All Sessions", isOn: model.peek.isShown) { model.togglePeek() }
                .accessibilityIdentifier("peek-toggle")
            InboxGlyph()
            BarGlyph(symbol: "command", label: "Commands") { model.showingPalette = true }
                .accessibilityIdentifier("palette")
            BarGlyph(symbol: "plus", label: "New Session") { model.newSession(on: model.currentLink) }
                .accessibilityIdentifier("new-session")
                .disabled(model.currentLink?.status != .online)
        }
        // The strip's glyph size, which the inbox's tray takes here too. The bar keeps its height, so its
        // glyphs stop growing at the largest text sizes.
        .font(.callout)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, Metrics.near)
        // Clear of the window's controls, as the strip is, while the window is short of the screen.
        .containerCornerOffset(.leading, sizeToFit: true)
        .frame(height: CardHeader.height)
    }
}

/// A glyph in the sidebar's bar on a 44-point target, lit under the pointer, and on a soft disc while what
/// it shows is out.
private struct BarGlyph: View {
    let symbol: String
    let label: String
    var isOn = false
    /// What the dot on the symbol's corner stands for, while there is news he has not seen.
    var news: AttentionBoard.Mark?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol)
                    // The dot's middle on the symbol's top trailing corner, at every text size.
                    .overlay(alignment: .topTrailing) {
                        if let news {
                            AttentionMark(mark: news)
                                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                                .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] }
                        }
                    }
            }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(isOn ? .primary : .secondary)
        .frame(width: Metrics.touch, height: Metrics.touch)
        .background {
            if isOn {
                Circle()
                    .fill(Theme.pill)
                    .padding(Metrics.tight)
            }
        }
        .contentShape(.rect)
        .contentShape(.hoverEffect, .circle)
        .hoverEffect(.highlight)
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Narrows the list to the sessions with activity and back, with the dot while one of them finished or
/// needs him and he has not seen it.
private struct ActivityGlyph: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let showing = model.sidebar.showingActivity
        let news = TabAttention.news(in: model.groupedActivity(matching: FuzzyQuery("")))
        BarGlyph(
            symbol: "line.3.horizontal.decrease", label: showing ? "Clear Activity Filter" : "Filter by Activity",
            isOn: showing, news: news
        ) {
            model.toggleActivity()
        }
        .accessibilityIdentifier("activity-toggle")
        .accessibilityValue(AttentionMark.label(news))
    }
}

/// One host's sessions that the filter keeps, folder by folder.
private struct Machine: Identifiable {
    let link: HostLink
    let folders: [Folder]

    var id: String { link.host.id }

    @MainActor
    init(link: HostLink, query: FuzzyQuery, model: AppModel) {
        self.link = link
        let kept = model.tabSessions(on: link).filter { session in
            guard !query.isEmpty else { return true }
            let ref = SessionRef(host: link.host.id, name: session.name)
            return model.tabMembers(ref).contains { member in
                guard let memberLink = model.link(for: member),
                      let item = memberLink.sessions.first(where: { $0.name == member.name })
                else { return false }
                return FuzzyMatch.score(
                    query, [item.name, memberLink.host.name, item.command, item.folder].joined(separator: " ")
                ) != nil
            }
        }
        // Home first, then by name.
        folders = Dictionary(grouping: kept) { Folder.name(of: $0.folder) }
            .map { folder in
                let rows = folder.value.map { Folder.Row(id: SessionRef(host: link.host.id, name: $0.name), session: $0) }
                return Folder(host: link.host.id, name: folder.key, rows: rows)
            }
            .sorted { first, second in
                if (first.name == "~") != (second.name == "~") { return first.name == "~" }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }
}

/// The sessions whose open pane is in a folder of one name: a project, by the last part of its path.
private struct Folder: Identifiable {
    /// A session under the name it goes by across hosts: the Mac and the server can each have a session
    /// called python, and rows whose ids repeat go missing from the lazy stack.
    struct Row: Identifiable {
        let id: SessionRef
        let session: TmuxSession
    }

    let host: String
    let name: String
    /// In the order the strip lists them.
    let rows: [Row]

    var id: String { "\(host)/\(name)" }

    /// "~/Developer/lhun" is "lhun"; home stays "~".
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The filter, then every host's sessions under its name, folder by folder. A host or folder he folded shows
/// only its header, until the filter holds letters: then every group shows the rows it matches, and the
/// folds are back once it empties.
/// Narrowed to activity, the filter, then only the sessions with activity (SidebarActivity), each with its
/// host's glyph.
private struct SessionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter = ""
    @FocusState private var filtering: Bool

    var body: some View {
        let query = FuzzyQuery(filter)
        // Narrowed to activity, the rows stand alone, newest first, under no host or folder.
        let activity = model.sidebar.showsActivity ? model.groupedActivity(matching: query) : nil
        let machines = activity == nil ? model.links.map { Machine(link: $0, query: query, model: model) } : []
        let first = activity?.first?.id ?? machines.lazy.compactMap { $0.folders.first?.rows.first?.id }.first
        let firstTarget = activity?.first?.ref ?? first
        VStack(spacing: Metrics.near) {
            HStack(spacing: 0) {
                SidebarFilter(text: $filter, focused: $filtering) {
                    if let firstTarget { open(firstTarget, selectingMember: activity != nil) }
                } onEscape: {
                    filter = ""
                    filtering = false
                    model.focusTerminal()
                }
                SessionLayoutButton()
            }
            .padding(.horizontal, Metrics.near)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(activity ?? []) { row in
                        if let link = model.link(for: row.id),
                           let session = link.sessions.first(where: { $0.name == row.id.name }) {
                            SidebarRow(
                                link: link, session: session, activity: row,
                                isNext: filtering && !query.isEmpty && row.id == first, showsHost: true
                            ) {
                                open(row.ref, selectingMember: true)
                            }
                        }
                    }
                    ForEach(machines) { machine in
                        if query.isEmpty || !machine.folders.isEmpty {
                            let hostFold = fold(of: machine.id, holding: machine.folders.lazy.flatMap(\.rows), query: query)
                            MachineHeader(link: machine.link, fold: hostFold) { toggleFold(machine.id) }
                            if hostFold?.isFolded != true {
                                ForEach(machine.folders) { folder in
                                    // A folder without a name has no header to fold it by.
                                    let folderFold = folder.name.isEmpty ? nil : fold(of: folder.id, holding: folder.rows, query: query)
                                    if !folder.name.isEmpty {
                                        FolderHeader(host: machine.id, name: folder.name, fold: folderFold) {
                                            toggleFold(folder.id)
                                        }
                                    }
                                    if folderFold?.isFolded != true {
                                        ForEach(folder.rows) { row in
                                            SidebarRow(
                                                link: machine.link, session: row.session,
                                                isNext: filtering && !query.isEmpty && row.id == first
                                            ) {
                                                open(row.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if first == nil, !query.isEmpty || activity != nil {
                        Text(query.isEmpty ? "No programs are reporting activity" : "No sessions match")
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                            .padding(Metrics.near)
                    }
                }
                .padding(.horizontal, Metrics.near)
                .padding(.bottom, Metrics.inset)
            }
            .scrollIndicators(.hidden)
            // A scroll view runs on under the keyboard; the rows stop above it and its key row instead of
            // showing through the key row.
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
        .onAppear { model.refreshLists() }
        .onChange(of: filtering) { model.sidebar.filtering = filtering }
    }


    /// The filter stays as typed, so the next match is a tap away.
    private func open(_ ref: SessionRef, selectingMember: Bool = false) {
        filtering = false
        if selectingMember { model.select(ref) }
        else { model.selectTab(ref) }
        model.focusTerminal()
    }

    /// How a host's or folder's group stands while the filter is empty: open, or folded with how many
    /// sessions it holds and the news among them he has not seen. Nil while the filter holds letters, when
    /// nothing folds.
    private func fold(of group: String, holding rows: some Collection<Folder.Row>, query: FuzzyQuery) -> GroupFold? {
        guard query.isEmpty else { return nil }
        guard model.sidebar.folded.contains(group) else { return .open }
        return .folded(
            count: rows.count, news: model.tabNews(in: rows.lazy.map(\.id))
        )
    }

    private func toggleFold(_ group: String) {
        model.sidebar.fold(group, animated: !reduceMotion)
    }
}

/// Narrows the list as he types. Return opens the first session left; Escape empties it and gives the keys
/// back to the terminal. Lhûn's own field rather than the system's search field, whose clear button UI
/// tests could not reach by an id.
private struct SidebarFilter: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: Metrics.near) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Filter", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused(focused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) {
                    onEscape()
                    return .handled
                }
                .accessibilityIdentifier("sidebar.filter")
        }
        // The text 8 points from the field's edges, so the field grows with the text size.
        .padding(.vertical, Metrics.near)
        .padding(.leading, Metrics.near)
        // Clear of the clear button over the field's end.
        .padding(.trailing, text.isEmpty ? Metrics.near : Metrics.touch)
        .background(Theme.pill, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(alignment: .trailing) {
            if !text.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.filter.clear")
            }
        }
        .font(.body)
    }
}

/// A host's or folder's group: open, or folded away with how many sessions it holds and the strongest
/// news among them he has not seen.
private enum GroupFold: Equatable {
    case open
    case folded(count: Int, news: AttentionBoard.Mark?)

    var isFolded: Bool {
        if case .folded = self { true } else { false }
    }

    /// What VoiceOver and UI tests read, as in "folded, 2 sessions, needs you".
    @MainActor
    var label: String {
        switch self {
        case .open: "open"
        case let .folded(count, news):
            ["folded", count == 1 ? "1 session" : "\(count) sessions", news.map { AttentionMark.label($0) }]
                .compactMap(\.self).joined(separator: ", ")
        }
    }
}

/// A host's or folder's header. While the filter is empty a tap folds its rows away, or brings them back:
/// the chevron at its end points down while they show. Folded, the header shows the dot while one of its
/// sessions finished or needs him and he has not seen it. While the filter holds letters, every group
/// shows the rows it matches and the header only names it.
private struct GroupHeader<Title: View>: View {
    let fold: GroupFold?
    let toggle: () -> Void
    @ViewBuilder let title: Title

    var body: some View {
        if let fold {
            Button(action: toggle) {
                HStack(spacing: Metrics.near) {
                    title
                    Spacer(minLength: 0)
                    FoldSign(fold: fold)
                }
                .padding(Metrics.near)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, .rect(cornerRadius: Metrics.radius, style: .continuous))
            .hoverEffect(.highlight)
            .accessibilityValue(fold.label)
        } else {
            title
                .padding(Metrics.near)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}

/// A header's end: the dot while a session folded under it finished or needs him and he has not seen it,
/// then the chevron.
private struct FoldSign: View {
    let fold: GroupFold

    var body: some View {
        HStack(spacing: Metrics.near) {
            if case let .folded(_, news?) = fold {
                AttentionMark(mark: news)
            }
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .rotationEffect(.degrees(fold.isFolded ? -90 : 0))
        }
        .accessibilityHidden(true)
    }
}

/// A host's glyph and name, and how it is doing while it is not online.
private struct MachineHeader: View {
    let link: HostLink
    let fold: GroupFold?
    let toggle: () -> Void

    var body: some View {
        GroupHeader(fold: fold, toggle: toggle) {
            HStack(spacing: Metrics.near) {
                // Over the rows' program marks, so the host's name starts where theirs do.
                Image(systemName: link.host.symbol)
                    .font(.subheadline)
                    .frame(minWidth: SidebarRow.iconSize)
                Text(link.host.name)
                    .font(.footnote.weight(.semibold))
                if link.status != .online {
                    Text(link.status.label)
                        .font(.footnote)
                }
            }
        }
        .foregroundStyle(Theme.detail)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.host.\(link.host.id)")
        // Room between one host's group and the one above it.
        .padding(.top, Metrics.near)
    }
}

/// A project's name, above its sessions.
private struct FolderHeader: View {
    let host: String
    let name: String
    let fold: GroupFold?
    let toggle: () -> Void

    var body: some View {
        GroupHeader(fold: fold, toggle: toggle) {
            Text(name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.detail)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.folder.\(host).\(name)")
    }
}

private struct SidebarRow: View {
    /// The program's mark beside the row's two lines, and the width of the host glyph's column above the
    /// marks.
    static let iconSize: CGFloat = 20

    let link: HostLink
    let session: TmuxSession
    var activity: TabAttention?
    /// The row Return opens, while he types in the filter.
    let isNext: Bool
    /// In the activity view, whose rows sit under no host: the host's glyph after the name.
    var showsHost = false
    let open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let ref = SessionRef(host: link.host.id, name: session.name)
        let members = model.tabMembers(ref)
        let isOpen = model.selection.map { model.tabRoot(for: $0) == ref } ?? false
        let attention = activity ?? model.tabAttention(ref)
        let mark = attention?.mark
        let status = attention?.status
        let doing = attention?.doing ?? session.task ?? session.command
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: Metrics.near) {
                    TabProgramMarks(ref: ref, size: Self.iconSize, background: isOpen ? Theme.raised : Theme.wash)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(session.name)
                                .foregroundStyle(.primary)
                            if session.windows > 1 {
                                Text(":\(session.window)")
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.detail)
                            }
                            if showsHost {
                                Image(systemName: link.host.symbol)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.detail)
                                    .padding(.leading, Metrics.tight)
                                    .accessibilityLabel(link.host.name)
                            }
                        }
                        .font(.subheadline)
                        Text(doing)
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineLimit(1)
                .padding(Metrics.near)
                .frame(minHeight: Metrics.touch)
                .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.\(link.host.id).\(session.name)")
            .accessibilityLabel(
                [
                    session.windows > 1 ? "\(session.name):\(session.window)" : session.name,
                    doing,
                    members.count > 1 ? "\(members.count) terminals" : "",
                    showsHost ? link.host.name : ""
                ].filter { !$0.isEmpty }.joined(separator: ", ")
            )
            .accessibilityValue(AttentionMark.label(mark, status: status))
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            TabActivityButton(
                ref: ref, arrowEdge: .leading,
                identifier: "sidebar.more.\(link.host.id).\(session.name)"
            )
        }
        .background { background(isOpen: isOpen) }
        .contentShape(.hoverEffect, .rect(cornerRadius: Metrics.radius, style: .continuous))
        .hoverEffect(.highlight)
        .contextMenu { actions(ref) }
        .onDrag { ref.itemProvider() }
        .hoverPicture(ref, place: .beside)
        .onAppear { SessionSidebar.rows += 1 }
        .onDisappear { SessionSidebar.rows -= 1 }
    }

    @ViewBuilder
    private func actions(_ ref: SessionRef) -> some View {
        if model.canAskAkyl {
            Button("Ask Akyl", systemImage: "bubble.left") { model.askAkyl(about: ref) }
        }
        Button("Close Tab", systemImage: "xmark") { model.detachTab(ref) }
        Button("Rename…", systemImage: "pencil") { model.renaming = ref }
        Button("Kill Session", systemImage: "xmark", role: .destructive) { model.killing = ref }
    }

    @ViewBuilder
    private func background(isOpen: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        if isOpen {
            shape.fill(Theme.raised)
        } else if isNext {
            shape.fill(Theme.pill)
        }
    }

}
