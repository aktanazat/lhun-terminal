import CoreGraphics
import Foundation

indirect enum CardTree: Codable, Equatable, Sendable {
    case leaf(SessionRef)
    case split(stacked: Bool, share: Double, first: CardTree, second: CardTree)

    var members: [SessionRef] {
        var result: [SessionRef] = []
        appendMembers(to: &result)
        return result
    }

    func appendMembers(to result: inout [SessionRef]) {
        switch self {
        case .leaf(let ref): result.append(ref)
        case .split(_, _, let first, let second):
            first.appendMembers(to: &result)
            second.appendMembers(to: &result)
        }
    }

    func contains(_ ref: SessionRef) -> Bool {
        switch self {
        case .leaf(let member): member == ref
        case .split(_, _, let first, let second): first.contains(ref) || second.contains(ref)
        }
    }

    var stacked: Bool {
        if case .split(let stacked, _, _, _) = self { return stacked }
        return false
    }

    static func pair(_ members: [SessionRef], stacked: Bool, share: CGFloat = 0.5) -> CardTree? {
        guard let first = members.first else { return nil }
        guard members.count > 1 else { return .leaf(first) }
        return .split(stacked: stacked, share: Double(share), first: .leaf(first), second: .leaf(members[1]))
    }

    func removing(_ refs: Set<SessionRef>) -> CardTree? {
        switch self {
        case .leaf(let ref): refs.contains(ref) ? nil : self
        case .split(let stacked, let share, let first, let second):
            switch (first.removing(refs), second.removing(refs)) {
            case (nil, nil): nil
            case (let kept?, nil), (nil, let kept?): kept
            case (let left?, let right?):
                .split(stacked: stacked, share: share, first: left, second: right)
            }
        }
    }

    func renaming(_ ref: SessionRef, to renamed: SessionRef) -> CardTree {
        switch self {
        case .leaf(let member): .leaf(member == ref ? renamed : member)
        case .split(let stacked, let share, let first, let second):
            .split(stacked: stacked, share: share, first: first.renaming(ref, to: renamed),
                   second: second.renaming(ref, to: renamed))
        }
    }

    func inserting(_ ref: SessionRef, beside anchor: SessionRef, on half: Half) -> CardTree {
        switch self {
        case .leaf(let member):
            guard member == anchor else { return self }
            return .split(stacked: half.stacks, share: 0.5,
                          first: .leaf(half.isFirst ? ref : member),
                          second: .leaf(half.isFirst ? member : ref))
        case .split(let stacked, let share, let first, let second):
            if first.contains(anchor) {
                return .split(stacked: stacked, share: share, first: first.inserting(ref, beside: anchor, on: half),
                              second: second)
            }
            return .split(stacked: stacked, share: share, first: first,
                          second: second.inserting(ref, beside: anchor, on: half))
        }
    }

    func resizing(at path: [Int], to share: CGFloat) -> CardTree {
        resizing(at: path[...], to: share)
    }

    private func resizing(at path: ArraySlice<Int>, to share: CGFloat) -> CardTree {
        guard case .split(let stacked, let current, let first, let second) = self else { return self }
        guard let branch = path.first else {
            return .split(stacked: stacked, share: Double(CardShares.clamped(share)), first: first, second: second)
        }
        return .split(stacked: stacked, share: current,
                      first: branch == 0 ? first.resizing(at: path.dropFirst(), to: share) : first,
                      second: branch == 1 ? second.resizing(at: path.dropFirst(), to: share) : second)
    }

    func nearestSplit(to ref: SessionRef, path: [Int] = []) -> [Int]? {
        guard case .split(_, _, let first, let second) = self else { return nil }
        if first.contains(ref) { return first.nearestSplit(to: ref, path: path + [0]) ?? path }
        if second.contains(ref) { return second.nearestSplit(to: ref, path: path + [1]) ?? path }
        return nil
    }

    func share(at path: [Int]) -> CGFloat? {
        share(at: path[...])
    }

    private func share(at path: ArraySlice<Int>) -> CGFloat? {
        guard case .split(_, let share, let first, let second) = self else { return nil }
        guard let branch = path.first else { return CGFloat(share) }
        return (branch == 0 ? first : second).share(at: path.dropFirst())
    }
    func isFirst(_ ref: SessionRef, at path: ArraySlice<Int>) -> Bool? {
        guard case .split(_, _, let first, let second) = self else { return nil }
        guard let branch = path.first else { return first.contains(ref) }
        return (branch == 0 ? first : second).isFirst(ref, at: path.dropFirst())
    }
}

struct FloatingCard: Codable, Equatable, Sendable {
    var ref: SessionRef
    var bounds: CGRect
    var returnLayout: CardTree? = nil
}

struct Workspace: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var root: SessionRef
    var layout: CardTree?
    var floating: [FloatingCard]
    var focused: SessionRef
    var zoomed: SessionRef?

    var members: [SessionRef] {
        var result: [SessionRef] = []
        layout?.appendMembers(to: &result)
        for card in floating { result.append(card.ref) }
        return result
    }
    var stacked: Bool { layout?.stacked ?? false }
    func contains(_ ref: SessionRef) -> Bool { layout?.contains(ref) == true || floating.contains { $0.ref == ref } }

    init(id: UUID = UUID(), root: SessionRef? = nil, members: [SessionRef], focused: SessionRef? = nil,
         stacked: Bool = false, zoomed: SessionRef? = nil, share: CGFloat = 0.5) {
        precondition(!members.isEmpty && members.count <= 2 && Set(members).count == members.count)
        self.init(id: id, root: root, layout: CardTree.pair(members, stacked: stacked, share: share),
                  floating: [], focused: focused, zoomed: zoomed)
    }

    init(id: UUID = UUID(), root: SessionRef? = nil, layout: CardTree?, floating: [FloatingCard] = [],
         focused: SessionRef? = nil, zoomed: SessionRef? = nil) {
        var members: [SessionRef] = []
        layout?.appendMembers(to: &members)
        for card in floating { members.append(card.ref) }
        precondition(!members.isEmpty && Set(members).count == members.count)
        self.id = id
        self.layout = layout
        self.floating = floating
        self.root = root.flatMap { members.contains($0) ? $0 : nil } ?? members[0]
        self.focused = focused.flatMap { members.contains($0) ? $0 : nil } ?? members[0]
        self.zoomed = members.count > 1 ? zoomed.flatMap { members.contains($0) ? $0 : nil } : nil
        if let zoomed = self.zoomed { self.focused = zoomed }
    }

    mutating func remove(_ refs: Set<SessionRef>) {
        layout = layout?.removing(refs)
        floating.removeAll { refs.contains($0.ref) }
        let remaining = members
        guard let first = remaining.first else { return }
        if !remaining.contains(root) { root = first }
        if !remaining.contains(focused) { focused = first }
        if remaining.count < 2 || zoomed.map(refs.contains) == true { zoomed = nil }
    }

    mutating func open(_ ref: SessionRef, on half: Half, beside anchor: SessionRef?) {
        let previousRoot = root
        remove([ref])
        if let anchor, let index = floating.firstIndex(where: { $0.ref == anchor }) {
            floating.remove(at: index)
            if let layout, let neighbor = layout.members.first {
                self.layout = layout.inserting(anchor, beside: neighbor, on: .right)
            } else {
                layout = .leaf(anchor)
            }
        }
        if let layout {
            let neighbor = anchor.flatMap { layout.members.contains($0) ? $0 : nil } ?? layout.members.first
            if let neighbor { self.layout = layout.inserting(ref, beside: neighbor, on: half) }
        } else {
            layout = .leaf(ref)
        }
        if contains(previousRoot) { root = previousRoot }
        focused = ref
        zoomed = nil
    }

    mutating func toggleFloating(_ ref: SessionRef) {
        if let index = floating.firstIndex(where: { $0.ref == ref }) {
            let card = floating.remove(at: index)
            if let former = card.returnLayout, former.removing([ref]) == layout {
                layout = former
            } else if let layout, let neighbor = layout.members.first {
                self.layout = layout.inserting(ref, beside: neighbor, on: .right)
            } else {
                layout = .leaf(ref)
            }
        } else {
            let former = layout
            layout = layout?.removing([ref])
            floating.append(FloatingCard(ref: ref, bounds: CGRect(x: 0.17, y: 0.14, width: 0.58, height: 0.58),
                                         returnLayout: former))
        }
        zoomed = nil
        focused = ref
    }

    mutating func bringForward(_ ref: SessionRef) {
        guard let index = floating.firstIndex(where: { $0.ref == ref }) else { return }
        floating.append(floating.remove(at: index))
    }

    private enum CodingKeys: String, CodingKey {
        case id, root, members, stacked, focused, zoomed, layout, floating
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let root = try values.decode(SessionRef.self, forKey: .root)
        let focused = try values.decode(SessionRef.self, forKey: .focused)
        let zoomed = try values.decodeIfPresent(SessionRef.self, forKey: .zoomed)
        if values.contains(.layout) {
            let layout = try values.decodeIfPresent(CardTree.self, forKey: .layout)
            let floating = try values.decode([FloatingCard].self, forKey: .floating)
            let members = (layout?.members ?? []) + floating.map(\.ref)
            guard !members.isEmpty, Set(members).count == members.count else {
                throw DecodingError.dataCorruptedError(forKey: .layout, in: values,
                                                       debugDescription: "Invalid workspace members")
            }
            self.init(id: id, root: root, layout: layout, floating: floating, focused: focused, zoomed: zoomed)
        } else {
            let members = try values.decode([SessionRef].self, forKey: .members)
            let stacked = try values.decode(Bool.self, forKey: .stacked)
            guard (1...2).contains(members.count), Set(members).count == members.count else {
                throw DecodingError.dataCorruptedError(forKey: .members, in: values,
                                                       debugDescription: "Invalid workspace members")
            }
            self.init(id: id, root: root, members: members, focused: focused, stacked: stacked, zoomed: zoomed)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(root, forKey: .root)
        try values.encode(focused, forKey: .focused)
        try values.encodeIfPresent(zoomed, forKey: .zoomed)
        try values.encode(layout, forKey: .layout)
        try values.encode(floating, forKey: .floating)
    }
}

struct WorkspaceStore: Codable, Equatable {
    private(set) var groups: [Workspace] = []
    private(set) var activeID: UUID?
    private(set) var shares: CardShares

    var active: Workspace? { groups.first { $0.id == activeID } }
    var selection: SessionRef? { active?.focused }
    var panes: [SessionRef] { active?.members ?? [] }
    var focusOrder: [SessionRef] {
        guard let active else { return [] }
        var refs = active.layout?.members ?? []
        refs.reserveCapacity(refs.count + active.floating.count)
        let tiledCount = refs.count
        for card in active.floating {
            let ref = card.ref
            let next = refs[tiledCount...].firstIndex {
                ref.host == $0.host ? ref.name < $0.name : ref.host < $0.host
            } ?? refs.endIndex
            refs.insert(ref, at: next)
        }
        return refs
    }
    var stacked: Bool { active?.stacked ?? false }
    var zoomed: SessionRef? { active?.zoomed }
    var layout: CardTree? { active?.layout }
    var floating: [FloatingCard] { active?.floating ?? [] }
    func isFloating(_ ref: SessionRef) -> Bool { active?.floating.contains { $0.ref == ref } ?? false }

    init(selection: SessionRef? = nil, panes: [SessionRef] = [], stacked: Bool = false,
         shares: CardShares = CardShares()) {
        self.shares = shares
        var unique: [SessionRef] = []
        for ref in panes where !unique.contains(ref) { unique.append(ref) }
        if !unique.isEmpty {
            let group = Workspace(members: Array(unique.prefix(2)), focused: selection, stacked: stacked,
                                  share: shares.share(of: Array(unique.prefix(2))))
            groups.append(group)
            activeID = group.id
            for ref in unique.dropFirst(2) { groups.append(Workspace(members: [ref])) }
        }
        if let selection { selectMember(selection) }
    }

    func group(for ref: SessionRef) -> Workspace? {
        groups.first { $0.contains(ref) }
    }

    func tabRoot(for ref: SessionRef) -> SessionRef { group(for: ref)?.root ?? ref }
    func tabMembers(_ ref: SessionRef) -> [SessionRef] { group(for: ref)?.members ?? [ref] }

    func unlisted(on host: String, sessions: Set<String>, attached: Set<SessionRef>) -> Set<SessionRef> {
        Set(groups.flatMap(\.members).filter {
            $0.host == host && !sessions.contains($0.name) && !attached.contains($0)
        })
    }

    mutating func selectTab(_ ref: SessionRef) {
        if let group = group(for: ref) { activeID = group.id }
        else {
            let group = Workspace(members: [ref])
            groups.append(group)
            activeID = group.id
        }
    }

    mutating func selectMember(_ ref: SessionRef) {
        selectTab(ref)
        guard let index = groups.firstIndex(where: { $0.id == activeID }) else { return }
        groups[index].focused = ref
        groups[index].bringForward(ref)
        if let zoomed = groups[index].zoomed, zoomed != ref { groups[index].zoomed = nil }
    }

    mutating func clearSelection() { activeID = nil }

    mutating func open(_ ref: SessionRef, on half: Half, over covered: SessionRef?,
                       focusing: SessionRef? = nil, beside anchor: SessionRef? = nil) {
        guard let target = anchor.flatMap({ group(for: $0) }) ?? active else {
            selectMember(ref)
            return
        }
        var next = target
        next.open(ref, on: half, beside: anchor ?? covered ?? target.focused)
        if next.members.count == 2 {
            next.layout = next.layout?.resizing(at: [], to: shares.share(of: next.members))
        }
        if let focusing, next.members.contains(focusing) { next.focused = focusing }
        restore(next)
    }

    mutating func restore(_ workspace: Workspace) {
        let incoming = Set(workspace.members)
        let displaced = groups.first { $0.id == workspace.id }?.members.filter { !incoming.contains($0) } ?? []
        for index in groups.indices where groups[index].id != workspace.id && groups[index].members.contains(where: incoming.contains) {
            groups[index].remove(incoming)
        }
        groups.removeAll { $0.members.isEmpty }
        if let index = groups.firstIndex(where: { $0.id == workspace.id }) { groups[index] = workspace }
        else { groups.append(workspace) }
        for ref in displaced { groups.append(Workspace(members: [ref])) }
        activeID = workspace.id
    }

    mutating func toggleZoom(_ ref: SessionRef) {
        guard let index = groups.firstIndex(where: { $0.id == activeID }),
              groups[index].members.count > 1, groups[index].members.contains(ref) else { return }
        groups[index].zoomed = groups[index].zoomed == nil ? ref : nil
        groups[index].focused = ref
    }

    mutating func toggleFloating(_ ref: SessionRef) {
        guard let index = groups.firstIndex(where: { $0.id == activeID }),
              groups[index].members.contains(ref) else { return }
        groups[index].toggleFloating(ref)
    }

    mutating func moveFloating(_ ref: SessionRef, by change: CGSize, in size: CGSize) {
        guard let index = groups.firstIndex(where: { $0.id == activeID }),
              let floating = groups[index].floating.firstIndex(where: { $0.ref == ref }),
              size.width > 0, size.height > 0 else { return }
        var bounds = groups[index].floating[floating].bounds
        bounds.origin.x = min(max(bounds.minX + change.width / size.width, 0), 1 - bounds.width)
        bounds.origin.y = min(max(bounds.minY + change.height / size.height, 0), 1 - bounds.height)
        groups[index].floating[floating].bounds = bounds
        groups[index].bringForward(ref)
    }

    mutating func resizeFloating(_ ref: SessionRef, by change: CGSize, in size: CGSize) {
        guard let index = groups.firstIndex(where: { $0.id == activeID }),
              let floating = groups[index].floating.firstIndex(where: { $0.ref == ref }),
              size.width > 0, size.height > 0 else { return }
        var bounds = groups[index].floating[floating].bounds
        bounds.size.width = min(max(bounds.width + change.width / size.width, 0.25), 1 - bounds.minX)
        bounds.size.height = min(max(bounds.height + change.height / size.height, 0.25), 1 - bounds.minY)
        groups[index].floating[floating].bounds = bounds
    }

    mutating func remove(_ refs: Set<SessionRef>) {
        for index in groups.indices where groups[index].members.contains(where: refs.contains) { groups[index].remove(refs) }
        groups.removeAll { $0.members.isEmpty }
        if let activeID, !groups.contains(where: { $0.id == activeID }) { self.activeID = nil }
    }

    mutating func rename(_ ref: SessionRef, to renamed: SessionRef) {
        guard ref != renamed else { return }
        remove([renamed])
        for index in groups.indices {
            groups[index].layout = groups[index].layout?.renaming(ref, to: renamed)
            for floating in groups[index].floating.indices {
                groups[index].floating[floating].returnLayout =
                    groups[index].floating[floating].returnLayout?.renaming(ref, to: renamed)
                if groups[index].floating[floating].ref == ref { groups[index].floating[floating].ref = renamed }
            }
            if groups[index].root == ref { groups[index].root = renamed }
            if groups[index].focused == ref { groups[index].focused = renamed }
            if groups[index].zoomed == ref { groups[index].zoomed = renamed }
        }
        shares.rename(ref, to: renamed)
    }

    mutating func resize(to share: CGFloat) { resize(at: [], to: share) }
    mutating func resize(at path: [Int], to share: CGFloat) {
        guard let index = groups.firstIndex(where: { $0.id == activeID }) else { return }
        groups[index].layout = groups[index].layout?.resizing(at: path, to: share)
        if path.isEmpty && groups[index].members.count == 2 { shares.set(share, for: panes) }
    }
    var focusedSplit: [Int]? { active.flatMap { $0.layout?.nearestSplit(to: $0.focused) } }
    var focusedShare: CGFloat { focusedSplit.flatMap { active?.layout?.share(at: $0) } ?? 0.5 }
    var focusedIsFirst: Bool {
        guard let active, let path = focusedSplit else { return true }
        return active.layout?.isFirst(active.focused, at: path[...]) ?? true
    }
    mutating func forgetShares(of ref: SessionRef) { shares.forget(ref) }

    func bookmark(host: String) -> AkylVisit.Navigation {
        AkylVisit.Navigation(
            host: host, panes: panes.map(\.line), selection: selection?.line, stacked: stacked,
            zoomed: zoomed?.line, shares: shares.stored, workspaceID: activeID, root: active?.root.line,
            layout: active?.layout, floating: active?.floating
        )
    }

    mutating func restore(_ navigation: AkylVisit.Navigation) {
        var seen: Set<SessionRef> = []
        let members = navigation.panes.compactMap { SessionRef(line: $0) }.filter { seen.insert($0).inserted }
        guard !members.isEmpty else { clearSelection(); return }
        let root = navigation.root.flatMap { SessionRef(line: $0) }
        let focused = navigation.selection.flatMap { SessionRef(line: $0) }
        let id = navigation.workspaceID ?? members.first.flatMap { group(for: $0)?.id } ?? UUID()
        let layout = navigation.layout ?? (navigation.floating == nil
            ? CardTree.pair(members, stacked: navigation.stacked,
                            share: CardShares(stored: navigation.shares).share(of: members)) : nil)
        let floating = navigation.floating ?? []
        let restored = Workspace(id: id, root: root, layout: layout, floating: floating,
                                 focused: focused, zoomed: navigation.zoomed.flatMap { SessionRef(line: $0) })
        restore(restored)
        if navigation.floating == nil {
            for ref in members.dropFirst(2) where group(for: ref) == nil { groups.append(Workspace(members: [ref])) }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, groups, activeID, shares }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported workspace version")
        }
        let saved = try values.decode([Workspace].self, forKey: .groups)
        shares = CardShares(stored: try values.decode([String: Double].self, forKey: .shares))
        var seen: Set<SessionRef> = []
        var ids: Set<UUID> = []
        for group in saved {
            let members = group.members.filter { !$0.host.isEmpty && !$0.name.isEmpty && seen.insert($0).inserted }
            guard !members.isEmpty else { continue }
            let id = ids.insert(group.id).inserted ? group.id : UUID()
            let layout = version == 1 && members.count == 2
                ? CardTree.pair(members, stacked: group.stacked, share: shares.share(of: members))
                : group.layout?.removing(Set(group.members).subtracting(members))
            let floating = group.floating.filter { members.contains($0.ref) }
            groups.append(Workspace(id: id, root: group.root, layout: layout, floating: floating,
                                    focused: group.focused, zoomed: group.zoomed))
        }
        let active = try values.decodeIfPresent(UUID.self, forKey: .activeID)
        activeID = active.flatMap { id in groups.contains(where: { $0.id == id }) ? id : nil }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(groups, forKey: .groups)
        try values.encodeIfPresent(activeID, forKey: .activeID)
        try values.encode(shares.stored, forKey: .shares)
    }
}

extension AkylVisit.Navigation {
    mutating func rename(_ ref: SessionRef, to renamed: SessionRef) {
        guard panes.contains(ref.line) else { return }
        var resized = CardShares(stored: shares)
        resized.rename(ref, to: renamed)
        self = Self(
            host: host, panes: panes.map { $0 == ref.line ? renamed.line : $0 },
            selection: selection == ref.line ? renamed.line : selection, stacked: stacked,
            zoomed: zoomed == ref.line ? renamed.line : zoomed, shares: resized.stored,
            workspaceID: workspaceID, root: root == ref.line ? renamed.line : root,
            layout: layout?.renaming(ref, to: renamed),
            floating: floating?.map { item in
                var item = item
                item.returnLayout = item.returnLayout?.renaming(ref, to: renamed)
                if item.ref == ref { item.ref = renamed }
                return item
            }
        )
    }

    mutating func remove(_ refs: Set<SessionRef>) {
        let removed = Set(refs.map(\.line))
        guard panes.contains(where: removed.contains) else { return }
        let rest = panes.filter { !removed.contains($0) }
        var resized = CardShares(stored: shares)
        for ref in refs { resized.forget(ref) }
        self = Self(
            host: host, panes: rest, selection: selection.flatMap { rest.contains($0) ? $0 : nil } ?? rest.first,
            stacked: rest.count == 2 && stacked,
            zoomed: rest.count > 1 ? zoomed.flatMap { rest.contains($0) ? $0 : nil } : nil,
            shares: resized.stored, workspaceID: rest.isEmpty ? nil : workspaceID,
            root: root.flatMap { rest.contains($0) ? $0 : nil } ?? rest.first,
            layout: layout?.removing(refs), floating: floating?.filter { !refs.contains($0.ref) }
        )
    }
}
