import SwiftUI
import os

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "paths")

/// The path picker. "Insert Path" finds a file or folder below the session's folder and types it at the
/// cursor; "Get File" finds a file there and copies it to the device; "Go to Folder" walks the host's
/// folders and opens a new session in one. Each folder is one listing on the host; searching it happens
/// here, so typing never waits on the network.
@MainActor @Observable
final class PathPicker {
    enum Mode {
        case insert
        case getFile
        case goTo
    }

    /// What choosing a row asks of the app.
    enum Outcome {
        /// The picker stays open, showing another folder.
        case stay
        /// Type this at the cursor.
        case insert(String)
        /// Copy the file at this absolute path to the device.
        case getFile(String)
        /// Open a new session in this folder.
        case openSession(String)
    }

    struct Row: Identifiable {
        enum Kind {
            case recent, useFolder, openHere, up, folder, file
        }

        let kind: Kind
        /// Relative to the folder on show, folders ending in "/"; absolute for a recent path.
        let path: String
        let title: String
        /// The UTF-8 offsets in `title` of the letters the search matched.
        var matched: [Int] = []
        /// Gray words after the title: for "..", the name of the folder it goes up to.
        var detail = ""

        /// Entries are relative and never start with "/", so the fixed rows' ids cannot collide with them.
        var id: String {
            switch kind {
            case .recent: "/recent" + path
            case .useFolder, .openHere: "/here"
            case .up: "/up"
            case .folder, .file: path
            }
        }
    }

    let mode: Mode
    let link: HostLink
    var query = ""
    var highlighted = 0
    private(set) var rows: [Row] = []
    /// The folder on show, from "~" inside home; empty until the first listing arrives.
    private(set) var folderName = ""
    private(set) var isLoading = false
    private(set) var problem: String?
    private(set) var isCapped = false

    @ObservationIgnored private let session: SessionRef?
    @ObservationIgnored private let listings: PathListings
    @ObservationIgnored private var listing: PathListing?
    @ObservationIgnored private var showing: String?
    @ObservationIgnored private var home = ""
    /// The pane's folder as of this opening: paths inside it go in relative to it. Nil until the pane's
    /// own listing comes back; until then paths are spelled from "~".
    @ObservationIgnored private var paneFolder: String?
    /// Where the picker opened.
    @ObservationIgnored private var root: String?
    /// Where typed paths start: where the picker opened, until the user steps into another folder.
    @ObservationIgnored private var base: String?
    /// The subfolders of each folder listed while the picker is open, for walking typed paths.
    @ObservationIgnored private var seen: [String: [String]] = [:]
    @ObservationIgnored private var latest = 0
    /// The last search and its matches, which the next, longer search only has to look through.
    @ObservationIgnored private var narrowing: (query: FuzzyQuery, matches: [Int])?

    private static let shownRows = 150

    /// Opens on the session's folder, showing its last listing at once when there is one; without a
    /// session, "Go to Folder" opens on the host's home.
    init(mode: Mode, link: HostLink, session: SessionRef?, listings: PathListings) {
        self.mode = mode
        self.link = link
        self.session = session
        self.listings = listings
        guard let session else {
            load(.home, pane: false)
            return
        }
        if let folder = listings.paneFolder(of: session), let cached = listings.listing(on: link.host.id, at: folder, files: hasFiles) {
            root = folder
            show(cached)
        }
        load(.pane(session.name), pane: true)
    }

    private var hasFiles: Bool { mode != .goTo }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        highlighted = (highlighted + step + rows.count) % rows.count
    }

    /// Lists the folder when nothing is typed, otherwise ranks what is below it. In "Go to Folder" the
    /// text up to the last "/" is a path to walk (`PathListing.walk`) and the rest filters the folder it
    /// reaches. The picker never rewrites what was typed, so keys typed while a folder loads are kept.
    func search() {
        highlighted = 0
        var filter = Substring(query)
        if mode == .goTo {
            guard let base else {
                rows = []
                return
            }
            let slash = query.lastIndex(of: "/")
            let walked = PathListing.walk(slash.map { query[...$0] } ?? "", from: base, home: home) { seen[$0] }
            if walked.folder != showing {
                browse(walked.folder)
                return
            }
            guard walked.finished else {
                rows = []
                return
            }
            if let slash { filter = query[query.index(after: slash)...] }
        }
        guard let listing else {
            rows = []
            return
        }
        let fuzzy = FuzzyQuery(String(filter))
        guard !fuzzy.isEmpty else {
            narrowing = nil
            rows = browsingRows(listing)
            return
        }
        let candidates = hasFiles ? listing.paths : listing.folders
        let pool = narrowing.flatMap { $0.query.covers(fuzzy) ? $0.matches : nil }
        let matches = FuzzyMatch.rank(fuzzy, in: candidates, pool: pool)
        narrowing = (fuzzy, matches)
        rows = matches.prefix(Self.shownRows).map { index in
            let path = candidates[index]
            return Row(kind: path.hasSuffix("/") ? .folder : .file, path: path, title: path, matched: FuzzyMatch.positions(fuzzy, in: path))
        }
    }

    /// Runs a row, the highlighted one by default: a file or a recent path goes in at the cursor, or in
    /// "Get File" comes to the device, and a folder opens; in "Go to Folder", a folder opens a new session.
    func choose(_ index: Int? = nil) -> Outcome {
        let index = index ?? highlighted
        guard rows.indices.contains(index), let showing else { return .stay }
        let row = rows[index]
        switch row.kind {
        case .up:
            open(PathListing.parent(of: showing))
            return .stay
        case .folder where mode != .goTo:
            open(PathListing.join(showing, String(row.path.dropLast())))
            return .stay
        case .folder:
            return .openSession(PathListing.join(showing, String(row.path.dropLast())))
        case .openHere:
            return .openSession(showing)
        case .useFolder:
            return insert(showing == "/" ? showing : showing + "/")
        case .file where mode == .getFile:
            return .getFile(PathListing.join(showing, row.path))
        case .file:
            return insert(PathListing.join(showing, row.path))
        case .recent:
            return insert(row.path)
        }
    }

    /// Opens the folder on a row without choosing it.
    func stepIn(_ index: Int) {
        guard rows.indices.contains(index), rows[index].kind == .folder, let showing else { return }
        open(PathListing.join(showing, String(rows[index].path.dropLast())))
    }

    /// Up one folder, for Backspace with nothing typed.
    func goUp() {
        guard let showing, showing != "/" else { return }
        open(PathListing.parent(of: showing))
    }

    private func insert(_ path: String) -> Outcome {
        listings.remember(path, on: link.host.id)
        return .insert(Tmux.word(PathListing.spelling(of: path, from: paneFolder, home: home)) + " ")
    }

    /// Steps into `folder`: typing starts over from there.
    private func open(_ folder: String) {
        base = folder
        query = ""
        browse(folder)
    }

    /// Shows `folder`, at once from its kept listing when there is one, while a fresh listing loads.
    private func browse(_ folder: String) {
        if let cached = listings.listing(on: link.host.id, at: folder, files: hasFiles) {
            show(cached)
        } else {
            listing = nil
            showing = folder
            folderName = PathListing.name(of: folder, home: home)
            rows = []
            isCapped = false
            problem = nil
            narrowing = nil
        }
        load(.folder(folder), pane: false)
    }

    private func show(_ listing: PathListing) {
        self.listing = listing
        showing = listing.folder
        home = listing.home
        seen[listing.folder] = listing.folders
        if base == nil { base = listing.folder }
        folderName = PathListing.name(of: listing.folder, home: home)
        isCapped = listing.isCapped
        problem = nil
        narrowing = nil
        search()
    }

    /// One listing on the host. Only the newest request may change what is on show; an older one still
    /// fills the cache.
    private func load(_ start: Tmux.ListingStart, pane: Bool) {
        latest += 1
        let request = latest
        isLoading = true
        let files = hasFiles
        Task {
            defer {
                if request == latest { isLoading = false }
            }
            let output: String
            do {
                output = try await link.run(Tmux.listing(start, files: files), timeout: .seconds(10))
            } catch {
                log.error("\(self.link.host.name, privacy: .public) listing failed: \(error.localizedDescription, privacy: .public)")
                if request == latest { problem = pane ? "Can't find the session's folder" : "Can't open this folder" }
                return
            }
            guard let listing = PathListing(output: output) else {
                log.error("\(self.link.host.name, privacy: .public) listing unreadable: \(output.prefix(200), privacy: .public)")
                if request == latest { problem = "Can't read this folder" }
                return
            }
            listings.save(listing, on: link.host.id, files: files)
            // The listing of where the picker opened: typed paths start there until the user steps away.
            if pane || root == nil {
                if base == root { base = listing.folder }
                root = listing.folder
            }
            if pane, let session {
                paneFolder = listing.folder
                listings.setPaneFolder(listing.folder, of: session)
            }
            if request == latest { show(listing) }
        }
    }

    private func browsingRows(_ listing: PathListing) -> [Row] {
        var rows: [Row] = []
        switch mode {
        case .insert where listing.folder == root:
            rows += listings.recent(on: link.host.id).prefix(3).map { path in
                Row(kind: .recent, path: path, title: PathListing.spelling(of: path, from: paneFolder, home: home))
            }
        case .insert:
            rows.append(Row(kind: .useFolder, path: "", title: "Use this folder"))
        case .goTo:
            rows.append(Row(kind: .openHere, path: "", title: "New session here"))
        case .getFile:
            break
        }
        if listing.folder != "/" {
            let parent = PathListing.name(of: PathListing.parent(of: listing.folder), home: home)
            rows.append(Row(kind: .up, path: "..", title: "..", detail: (parent as NSString).lastPathComponent))
        }
        let entries = hasFiles ? listing.entries : listing.folders
        rows += entries.prefix(Self.shownRows).map { entry in
            Row(kind: entry.hasSuffix("/") ? .folder : .file, path: entry, title: entry)
        }
        return rows
    }
}

/// Listings the path picker has fetched, kept for the next time a folder opens; the folder each session's
/// pane was last in; and the paths last put in on each host. Only the newest few listings stay.
final class PathListings {
    private var listings: [String: PathListing] = [:]
    private var newest: [String] = []
    private var paneFolders: [SessionRef: String] = [:]
    private var recentPaths: [String: [String]] = [:]

    private static let keptListings = 4
    private static let keptPaths = 5

    func listing(on host: String, at folder: String, files: Bool) -> PathListing? {
        listings[key(host, folder, files)]
    }

    func save(_ listing: PathListing, on host: String, files: Bool) {
        let key = key(host, listing.folder, files)
        listings[key] = listing
        newest.removeAll { $0 == key }
        newest.append(key)
        while newest.count > Self.keptListings {
            listings[newest.removeFirst()] = nil
        }
    }

    func paneFolder(of session: SessionRef) -> String? {
        paneFolders[session]
    }

    func setPaneFolder(_ folder: String, of session: SessionRef) {
        paneFolders[session] = folder
    }

    /// Absolute paths, newest first.
    func recent(on host: String) -> [String] {
        recentPaths[host] ?? []
    }

    func remember(_ path: String, on host: String) {
        var paths = recentPaths[host] ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        recentPaths[host] = Array(paths.prefix(Self.keptPaths))
    }

    private func key(_ host: String, _ folder: String, _ files: Bool) -> String {
        "\(host)\n\(folder)\n\(files)"
    }
}

struct PathPickerView: View {
    @Environment(AppModel.self) private var model
    @Bindable var picker: PathPicker

    var body: some View {
        PaletteCard(
            prompt: prompt,
            query: $picker.query,
            fieldID: "paths.query",
            highlightedID: picker.rows.indices.contains(picker.highlighted) ? picker.rows[picker.highlighted].id : nil,
            onMove: picker.move,
            onSubmit: { model.finishPathPicker(picker.choose()) },
            onClose: model.closePathPicker,
            onDeleteEmpty: picker.goUp
        ) {
            Text(picker.folderName.isEmpty ? "…" : picker.folderName)
                .font(.footnote)
                .foregroundStyle(Theme.detail)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 240, alignment: .leading)
                .layoutPriority(1)
                .accessibilityIdentifier("paths.folder")
        } rows: {
            ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                PathRow(row: row, mode: picker.mode, folderName: picker.folderName, isHighlighted: index == picker.highlighted) {
                    model.finishPathPicker(picker.choose(index))
                } stepIn: {
                    picker.stepIn(index)
                }
                .id(row.id)
            }
            if picker.rows.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(picker.problem == nil ? Theme.detail : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.touch)
            }
        }
        .onChange(of: picker.query) { picker.search() }
        .onChange(of: model.showingPalette) { _, showing in
            if showing { model.closePathPicker() }
        }
        .onChange(of: model.selection) { model.closePathPicker() }
    }

    private var prompt: String {
        switch picker.mode {
        case .insert: "Find a file or folder"
        case .getFile: "Find a file to get"
        case .goTo: "Filter folders, / to step in"
        }
    }

    private var status: String {
        if let problem = picker.problem { return problem }
        if picker.isLoading { return picker.mode == .goTo ? "Listing folders…" : "Listing files…" }
        if picker.query.isEmpty { return "Nothing here" }
        if picker.mode == .goTo { return "No matching folders" }
        // A file past the ones listed may still match.
        return picker.isCapped ? "No matching files in the first \(PathListing.fileCap.formatted())" : "No matching files"
    }
}

private struct PathRow: View {
    let row: PathPicker.Row
    let mode: PathPicker.Mode
    let folderName: String
    let isHighlighted: Bool
    let choose: () -> Void
    let stepIn: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: choose) {
                HStack(spacing: Metrics.near) {
                    title
                        .font(.subheadline)
                        .truncationMode(.middle)
                    Spacer(minLength: Metrics.near)
                    if row.kind == .folder, mode != .goTo {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                    }
                }
                .lineLimit(1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("paths.\(row.id)")
            if row.kind == .folder, mode == .goTo {
                Button(action: stepIn) {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.touch, height: Metrics.touch)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(row.path)")
            }
        }
        .paletteRow(isHighlighted: isHighlighted)
    }

    private var title: Text {
        switch row.kind {
        case .useFolder, .openHere:
            Text("\(row.title)  \(Text(folderName).foregroundStyle(Theme.detail))")
        case .up:
            Text("\(row.title)  \(Text(row.detail).foregroundStyle(Theme.detail))")
        default:
            Text(Self.marked(row.title, row.matched))
        }
    }

    /// The path with its folder part dimmed and the letters the search matched in semibold.
    private static func marked(_ path: String, _ matched: [Int]) -> AttributedString {
        let marks = Set(matched)
        let nameStart = path.dropLast().lastIndex(of: "/").map { path.utf8.distance(from: path.startIndex, to: $0) + 1 } ?? 0
        var text = AttributedString()
        var run = ""
        var runStyle = (bold: false, dim: false)
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runStyle.bold { piece.swiftUI.font = .subheadline.weight(.semibold) }
            piece.swiftUI.foregroundColor = runStyle.dim ? Theme.detail : .primary
            text += piece
            run = ""
        }
        var offset = 0
        for character in path {
            let style = (bold: marks.contains(offset), dim: offset < nameStart && !marks.contains(offset))
            if style != runStyle {
                flush()
                runStyle = style
            }
            run.append(character)
            offset += character.utf8.count
        }
        flush()
        return text
    }
}

extension AppModel {
    /// ⌘P and the key row's path key: "Insert Path" over the open session, or closes the picker.
    func togglePathPicker() {
        togglePathPicker(.insert)
    }

    /// Opens the picker in `mode`, or closes it when it is already showing that mode. "Insert Path" and
    /// "Get File" need an open session; "Go to Folder" starts on the current host's home without one. A
    /// picker in another mode gives way to the new one, whose field keeps the keyboard.
    func togglePathPicker(_ mode: PathPicker.Mode) {
        if pathPicker?.mode == mode { return closePathPicker() }
        let session = selection
        let host = session.flatMap(link(for:)) ?? (mode == .goTo ? currentLink : nil)
        guard let host, mode == .goTo || selectedTerminal != nil else { return closePathPicker() }
        showingPalette = false
        pathPicker = PathPicker(mode: mode, link: host, session: session, listings: pathListings)
        probe?.record("path picker")
    }

    /// Closes the picker and gives the keyboard back to the terminal.
    func closePathPicker() {
        guard pathPicker != nil else { return }
        pathPicker = nil
        takeKeyboardBack()
    }

    func finishPathPicker(_ outcome: PathPicker.Outcome) {
        guard let picker = pathPicker else { return }
        switch outcome {
        case .stay:
            break
        case .insert(let text):
            closePathPicker()
            selectedTerminal?.paste(text)
        case .getFile(let path):
            closePathPicker()
            getFile(path, on: picker.link)
        case .openSession(let folder):
            closePathPicker()
            // Named after the folder, so the pill says where it is.
            let name = Tmux.sessionName(for: folder.split(separator: "/").last.map(String.init) ?? "root", after: picker.link.sessions)
            newSession(named: name, in: folder, on: picker.link)
        }
    }
}
