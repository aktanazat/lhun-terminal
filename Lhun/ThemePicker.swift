import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "themes")

/// "Theme…" and "Theme for <host>…": the themes for the appearance on screen, the saved one checked, and the
/// row that imports a Ghostty theme file from this device. The app takes on each theme as the highlight
/// reaches it; Return or a tap keeps it, and Esc or a tap outside puts back the one before. The Mac's Ghostty
/// theme is read when the picker opens.
@MainActor @Observable
final class ThemePicker {
    /// The row that opens the file picker, apart from every theme's id.
    static let importID = "import-theme"

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// What the row tries; nil while it can't be chosen, as while the Mac's Ghostty theme is read.
        let look: HostLook?
        /// The theme `look` names.
        let theme: LhunTheme?
    }

    /// The Mac's Ghostty theme for this appearance, once read, or why there is none.
    enum Ghostty: Equatable {
        case reading
        case found(LhunTheme)
        case missing(String)
    }

    /// Whose theme: Lhûn's, or one host's.
    let host: Host?
    /// Whether the dark appearance's themes are listed.
    let dark: Bool
    var query = ""
    /// The query the rows were last built for.
    private var filteredQuery = ""
    private(set) var highlighted = 0
    private(set) var rows: [Row] = []
    private(set) var ghostty = Ghostty.reading
    /// A theme read from a file and tried, not yet kept: Return keeps it in the library, and the picker
    /// closing drops it.
    private(set) var candidate: LhunTheme?
    /// What went wrong with the last file picked, shown on the import row until another is.
    private(set) var importProblem: String?

    @ObservationIgnored private let store = ThemeStore.shared

    init(host: Host?, dark: Bool, mac: HostLink?) {
        self.host = host
        self.dark = dark
        rows = allRows
        highlighted = rows.firstIndex(where: isCurrent) ?? 0
        read(mac)
    }

    /// The saved choice: the row checked.
    func isCurrent(_ row: Row) -> Bool {
        guard let look = row.look else { return false }
        if let host { return look == store.looks[host.id]?[dark: dark] ?? .standard(for: host.id) }
        return look == .theme(store.chosen[dark: dark])
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        highlighted = (highlighted + step + rows.count) % rows.count
        show(highlighted)
    }

    /// Narrows the rows to what is typed, and tries the best match. A query the rows were already built for
    /// leaves them alone, so clearing the field for an import keeps the highlight the import set.
    func filter() {
        guard query != filteredQuery else { return }
        filteredQuery = query
        rows = matching()
        highlighted = 0
        show(highlighted)
    }

    /// The rows matching what is typed, best first; all of them, in order, when nothing is.
    private func matching() -> [Row] {
        let fuzzy = FuzzyQuery(query)
        let all = allRows
        return fuzzy.isEmpty ? all : FuzzyMatch.rank(fuzzy, in: all.map(\.title)).map { all[$0] }
    }

    /// Keeps a row, the highlighted one unless another is named. False when it can't be chosen.
    func choose(_ index: Int? = nil) -> Bool {
        let target = index ?? highlighted
        guard let preview = preview(of: target) else { return false }
        let adopted = rows.indices.contains(target) && rows[target].id == candidate?.id ? candidate : nil
        do {
            try store.keep(preview, adopting: adopted)
        } catch {
            importProblem = "Couldn't save theme. Check device storage."
            rows = matching()
            highlighted = rows.firstIndex { $0.id == Self.importID } ?? 0
            show(highlighted)
            return false
        }
        candidate = nil
        return true
    }

    // MARK: Importing

    /// Whether the highlight is on the import row, which Return opens the file picker for.
    var choosingImport: Bool {
        rows.indices.contains(highlighted) && rows[highlighted].id == Self.importID
    }

    /// Reads a picked file and tries the theme in it. A theme for the other appearance is not listed here,
    /// as the Mac's Ghostty theme is not, and the import row says so instead.
    func importTheme(at url: URL) {
        do {
            let theme = try store.theme(fromFile: url)
            guard theme.palette.isLight != dark else {
                candidate = nil
                importProblem = "\(theme.name) is a \(dark ? "light" : "dark") theme"
                clearQuery()
                rows = matching()
                highlighted = rows.firstIndex { $0.id == Self.importID } ?? 0
                show(highlighted)
                return
            }
            candidate = theme
            importProblem = nil
            clearQuery()
            rows = matching()
            highlighted = rows.firstIndex { $0.id == theme.id } ?? 0
            show(highlighted)
        } catch {
            importProblem = error.localizedDescription
            clearQuery()
            rows = matching()
            highlighted = rows.firstIndex { $0.id == Self.importID } ?? 0
            show(highlighted)
        }
    }

    /// The file picker failed on its own, as when the file it was given can't be reached.
    func importFailed(_ error: Error) {
        importProblem = error.localizedDescription
        clearQuery()
        rows = matching()
        highlighted = rows.firstIndex { $0.id == Self.importID } ?? 0
        show(highlighted)
    }

    /// Empties the field without filtering the list again: the caller builds the rows it needs.
    private func clearQuery() {
        query = ""
        filteredQuery = ""
    }

    /// Shows a row's look across the app, or the saved one while the row can't be chosen.
    private func show(_ index: Int) {
        store.setPreview(preview(of: index))
    }

    private func preview(of index: Int) -> ThemeStore.Preview? {
        guard rows.indices.contains(index), let look = rows[index].look else { return nil }
        return ThemeStore.Preview(host: host?.id, dark: dark, look: look, theme: rows[index].theme)
    }

    /// Lhûn's own looks for a host first, then Mies, the Mac's Ghostty theme, the row that imports a file,
    /// the rest by name, the imported themes among them.
    private var allRows: [Row] {
        var rows: [Row] = []
        let themes = LhunTheme.list(dark: dark)
        if host != nil {
            let lhun = store.theme(dark: dark).name
            rows.append(Row(id: "lhun", title: "Lhûn's Theme", detail: lhun, look: .lhun, theme: nil))
            rows.append(Row(id: "tinted", title: "Lhûn's Theme, Tinted", detail: lhun, look: .tinted, theme: nil))
        }
        rows.append(row(themes[0]))
        rows.append(ghosttyRow)
        rows.append(importRow)
        rows += (themes.dropFirst() + importedThemes).map(row)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return rows
    }

    /// The imported themes this appearance can show, the one a file just brought in among them.
    private var importedThemes: [LhunTheme] {
        var themes = store.imported.filter { $0.palette.isLight != dark }
        if let candidate, candidate.palette.isLight != dark, !themes.contains(where: { $0.id == candidate.id }) {
            themes.append(candidate)
        }
        return themes
    }

    private func row(_ theme: LhunTheme) -> Row {
        Row(id: theme.id, title: theme.name, detail: theme.id == candidate?.id ? "new" : "", look: .theme(theme.id), theme: theme)
    }

    private var importRow: Row {
        Row(
            id: Self.importID, title: "Import Theme File…", detail: importProblem ?? "Ghostty theme file",
            look: nil, theme: nil
        )
    }

    private var ghosttyRow: Row {
        let id = LhunTheme.ghosttyID, title = "Mac's Ghostty theme"
        return switch ghostty {
        case .reading: Row(id: id, title: title, detail: "reading…", look: nil, theme: nil)
        case .found(let theme): Row(id: id, title: title, detail: theme.name, look: .theme(id), theme: theme)
        case .missing(let reason): Row(id: id, title: title, detail: reason, look: nil, theme: nil)
        }
    }

    /// Reads the Mac's Ghostty theme, then puts its row in place, keeping the highlight where it was.
    private func read(_ mac: HostLink?) {
        guard let mac else {
            ghostty = .missing("can't reach the Mac")
            rows = matching()
            return
        }
        let dark = dark
        Task { [weak self] in
            let found: Ghostty
            do {
                if let read = try await GhosttyTheme.read(over: mac) {
                    for dark in [false, true] {
                        if let theme = read.themes[dark: dark] { ThemeStore.shared.refreshGhostty(theme, dark: dark) }
                    }
                    let name = dark ? read.names.dark : read.names.light
                    if let theme = read.themes[dark: dark] {
                        // Like every theme here, it is listed only in its own appearance.
                        found = theme.palette.isLight != dark ? .found(theme) : .missing("\(name) is a \(dark ? "light" : "dark") theme")
                    } else {
                        found = .missing("can't find \(name) on the Mac")
                    }
                } else {
                    found = .missing("no theme in its config")
                }
            } catch {
                log.error("Ghostty theme unreadable: \(error.localizedDescription, privacy: .public)")
                found = .missing("can't reach the Mac")
            }
            guard let self else { return }
            let highlightedID = rows.indices.contains(highlighted) ? rows[highlighted].id : nil
            ghostty = found
            rows = matching()
            highlighted = rows.firstIndex { $0.id == highlightedID } ?? 0
            // The highlight may sit on the row that just became choosable.
            if highlightedID == LhunTheme.ghosttyID, rows.indices.contains(highlighted) { show(highlighted) }
        }
    }
}

struct ThemePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var picker: ThemePicker
    @State private var importing = false
    /// Each import ends a sheet that took the keyboard: the field asks for it back (PaletteCard).
    @State private var focusRequest = 0

    var body: some View {
        PaletteCard(
            prompt: picker.host.map { "Choose a theme for \($0.phrase)" } ?? "Choose a theme",
            query: $picker.query,
            fieldID: "themes.query",
            highlightedID: picker.rows.indices.contains(picker.highlighted) ? picker.rows[picker.highlighted].id : nil,
            onMove: picker.move,
            onSubmit: {
                if picker.choosingImport {
                    importing = true
                } else if picker.choose() {
                    model.closeThemePicker()
                }
            },
            onClose: model.closeThemePicker,
            onDeleteEmpty: model.backFromThemePicker,
            focusRequest: focusRequest
        ) {
            ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                Button {
                    if row.id == ThemePicker.importID {
                        importing = true
                    } else if picker.choose(index) {
                        model.closeThemePicker()
                    }
                } label: {
                    ThemeRow(row: row, isHighlighted: index == picker.highlighted, isCurrent: picker.isCurrent(row))
                }
                .buttonStyle(.plain)
                .opacity(row.look == nil && row.id != ThemePicker.importID ? 0.45 : 1)
                .id(row.id)
                .accessibilityIdentifier("themes.\(row.id)")
                .accessibilityValue(picker.isCurrent(row) ? "current" : row.detail)
            }
            if picker.rows.isEmpty {
                Text("No theme by that name")
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
                    .frame(maxWidth: .infinity, minHeight: Metrics.touch)
            }
        }
        .onChange(of: picker.query) { picker.filter() }
        .onChange(of: model.showingPalette) { _, showing in
            if showing { model.closeThemePicker() }
        }
        // The list is the opening appearance's.
        .onChange(of: colorScheme) { model.closeThemePicker() }
        // Any file can be picked: whether it is a theme is decided by what it holds (GhosttyTheme.imported).
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            focusRequest += 1
            switch result {
            case .success(let url): picker.importTheme(at: url)
            case .failure(let error) where (error as? CocoaError)?.code == .userCancelled: break
            case .failure(let error): picker.importFailed(error)
            }
        }
    }
}

private struct ThemeRow: View {
    let row: ThemePicker.Row
    let isHighlighted: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: Metrics.near) {
            Text(row.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(row.detail)
                .font(.footnote)
                .foregroundStyle(Theme.detail)
                .truncationMode(.middle)
            Spacer(minLength: Metrics.near)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .lineLimit(1)
        .paletteRow(isHighlighted: isHighlighted)
    }
}

extension AppModel {
    /// Lists Lhûn's themes, or one host's, for the appearance on screen.
    func openThemePicker(for host: Host?, dark: Bool) {
        themePicker = ThemePicker(host: host, dark: dark, mac: links.first { $0.host.id == Host.mac.id })
    }

    /// Closes the picker: what it was trying goes, and what it kept stays.
    func closeThemePicker() {
        guard themePicker != nil else { return }
        ThemeStore.shared.setPreview(nil)
        themePicker = nil
        takeKeyboardBack()
    }

    /// Backspace with nothing typed: back to the palette the picker came from, up first, so its field takes
    /// the keyboard from the picker's.
    func backFromThemePicker() {
        showingPalette = true
        closeThemePicker()
    }
}
