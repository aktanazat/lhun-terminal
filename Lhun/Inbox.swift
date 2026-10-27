import SwiftUI
import os

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "inbox")

/// A session in the inbox: one that waits on him or finished while he was away, or the open session when
/// "Catch Up on This Session" opened the inbox.
struct InboxEntry: Identifiable {
    let ref: SessionRef
    let host: Host
    let session: TmuxSession
    /// Nil for the open session.
    let mark: AttentionBoard.Mark?
    /// What the program behind the mark reports, when it reports. Nil for the open session.
    let status: ProgramStatus?

    var id: String { "\(ref.host).\(ref.name)" }
}

/// ⌘⇧I: every session on both hosts that waits on him or finished while he was away, the waiting ones
/// first, each with the last lines on its screen and, when he asks, a few sentences on where it got to.
/// Each host's screens are read in one exec as the inbox opens; everything read and written goes when it
/// closes.
@MainActor @Observable
final class Inbox {
    /// The open session, listed first with its summary under way, when "Catch Up on This Session" opened
    /// the inbox.
    let pinned: SessionRef?
    var query = ""
    var highlighted = 0
    /// The last lines with words on each session's screen as the inbox opened, top to bottom.
    private(set) var lastLines: [SessionRef: [String]] = [:]
    /// The sessions whose screens the inbox read as it opened.
    private(set) var reading: Set<SessionRef> = []
    /// Hosts whose screens could not be read.
    private(set) var unreachable: Set<String> = []
    /// The summaries asked for.
    private(set) var catchUps: [SessionRef: CatchUp.State] = [:]

    @ObservationIgnored private let probe: Probe?
    @ObservationIgnored private var work: [Task<Void, Never>] = []

    init(pinned: SessionRef?, probe: Probe?) {
        self.pinned = pinned
        self.probe = probe
    }

    func move(_ step: Int, among count: Int) {
        guard count > 0 else { return }
        highlighted = (min(highlighted, count - 1) + step + count) % count
    }

    /// Whether every word typed is in the session's name, host, program, folder or last lines.
    func matches(_ entry: InboxEntry) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = ([entry.ref.name, entry.host.name, entry.session.command, entry.session.folder] + (lastLines[entry.ref] ?? []))
            .joined(separator: " ")
            .lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// Reads the screens of `entries`, in one exec per host.
    func readScreens(of entries: [InboxEntry], on links: [HostLink]) {
        for link in links {
            let refs = entries.map(\.ref).filter { $0.host == link.host.id }
            guard !refs.isEmpty else { continue }
            reading.formUnion(refs)
            let host = link.host
            work.append(Task { [weak self] in
                do {
                    let output = try await link.run(Tmux.screens(of: refs.map(\.name)), timeout: .seconds(10))
                    guard let self else { return }
                    let screens = Tmux.lastLines(output)
                    for ref in refs {
                        lastLines[ref] = screens[ref.name] ?? []
                    }
                    probe?.record("inbox lines", details: ["linesHost": host.id, "linesSessions": refs.count, "linesBytes": output.utf8.count])
                } catch {
                    guard !Task.isCancelled else { return }
                    log.error("\(host.name, privacy: .public) screens failed: \(error.localizedDescription, privacy: .public)")
                    self?.probe?.record("inbox lines", details: ["linesHost": host.id, "linesError": String(describing: error)])
                    self?.unreachable.insert(host.id)
                }
            })
        }
    }

    /// Reads the session's last 200 lines and has Apple's on-device model sum up where it got to, or says
    /// why it can't.
    func catchUp(on entry: InboxEntry, over link: HostLink) {
        let ref = entry.ref
        if let state = catchUps[ref], !state.canRetry { return }
        if let blocked = CatchUp.Unavailable.current {
            catchUps[ref] = .unavailable(blocked)
            probe?.record("catch up", details: ["catchUp": "unavailable", "catchUpReason": "\(blocked)"])
            return
        }
        catchUps[ref] = .reading
        let host = entry.host.phrase
        let subject = CatchUp.Subject(name: ref.name, host: host, folder: entry.session.folder)
        work.append(Task { [weak self] in
            let started = ContinuousClock.now
            let lines: [String]
            do {
                lines = CatchUp.excerpt(try await link.run(CatchUp.history(of: ref.name), timeout: .seconds(10)))
            } catch {
                if !Task.isCancelled { self?.catchUps[ref] = .failed("Can't reach \(host) to read its lines.") }
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard !lines.isEmpty else {
                catchUps[ref] = .failed("There's nothing on its screen to go on.")
                return
            }
            catchUps[ref] = .writing
            do {
                let summary = try await CatchUp.summarize(lines, about: subject)
                guard !Task.isCancelled else { return }
                catchUps[ref] = .written(summary.text)
                probe?.record("catch up", details: [
                    "catchUp": "written", "catchUpLines": summary.linesRead,
                    "catchUpContext": summary.contextSize, "catchUpCharacters": summary.text.count,
                    "catchUpMs": Int((ContinuousClock.now - started) / .milliseconds(1)),
                ])
            } catch {
                guard !Task.isCancelled else { return }
                log.error("catch up on \(ref.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                catchUps[ref] = .failed(CatchUp.message(for: error))
                probe?.record("catch up", details: ["catchUp": "failed", "catchUpError": String(describing: error)])
            }
        })
    }

    /// Stops reading and writing: the inbox is closing.
    func stop() {
        for task in work { task.cancel() }
        work = []
    }
}

extension AppModel {
    /// Sessions on both hosts that wait on him or finished while he was away, the waiting ones first, each
    /// group in host and list order. The open session is never one of them.
    var inboxEntries: [InboxEntry] {
        var waiting: [InboxEntry] = []
        var finished: [InboxEntry] = []
        for link in links {
            for session in link.sessions {
                let ref = SessionRef(host: link.host.id, name: session.name)
                let mark = attention.mark(ref, open: selection)
                let entry = InboxEntry(
                    ref: ref, host: link.host, session: session, mark: mark, status: attention.status(ref, open: selection)
                )
                switch mark {
                case .needsYou: waiting.append(entry)
                case .finished: finished.append(entry)
                case .working, nil: break
                }
            }
        }
        return waiting + finished
    }

    /// The inbox's rows: the session it pinned first, then `inboxEntries`.
    func inboxEntries(pinning pinned: SessionRef?) -> [InboxEntry] {
        guard let pinned, let link = link(for: pinned), let session = link.sessions.first(where: { $0.name == pinned.name })
        else { return inboxEntries }
        return [InboxEntry(ref: pinned, host: link.host, session: session, mark: nil, status: nil)]
            + inboxEntries.filter { $0.ref != pinned }
    }

    /// ⌘⇧I and the strip's tray: opens the inbox, or closes it.
    func toggleInbox() {
        if inbox == nil { openInbox() } else { closeInbox() }
    }

    /// Opens the inbox and reads its sessions' screens. With `catchingUp`, the open session comes first and
    /// its summary starts at once. It is up before a picker under it closes, so the picker's field hands the
    /// keyboard straight to the inbox's.
    func openInbox(catchingUp: Bool = false) {
        let inbox = Inbox(pinned: catchingUp ? selection : nil, probe: probe)
        dropInbox()
        self.inbox = inbox
        showingPalette = false
        closePathPicker()
        closeThemePicker()
        closePeek()
        let entries = inboxEntries(pinning: inbox.pinned)
        probe?.record("inbox", details: ["inboxRows": entries.count, "inboxPinned": inbox.pinned != nil])
        inbox.readScreens(of: entries, on: links)
        if let first = entries.first, first.ref == inbox.pinned, let link = link(for: first.ref) {
            inbox.catchUp(on: first, over: link)
        }
    }

    /// Closes the inbox, which lets go of every screen it read and summary it wrote, and gives the keyboard
    /// back to the terminal.
    func closeInbox() {
        guard inbox != nil else { return }
        dropInbox()
        takeKeyboardBack()
    }

    /// Opens the session on a row, which clears its mark. The session is chosen before the inbox closes,
    /// so the keyboard goes to it rather than to the session it replaces.
    func openFromInbox(_ ref: SessionRef) {
        select(ref)
        closeInbox()
    }

    /// Lets go of the inbox, its screens and summaries, and hands the keyboard nowhere.
    private func dropInbox() {
        guard let inbox else { return }
        inbox.stop()
        self.inbox = nil
        probe?.record("inbox closed")
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Bindable var inbox: Inbox

    var body: some View {
        let rows = model.inboxEntries(pinning: inbox.pinned).filter(inbox.matches)
        let highlighted = rows.isEmpty ? nil : min(inbox.highlighted, rows.count - 1)
        PaletteCard(
            prompt: "Filter the inbox",
            query: $inbox.query,
            fieldID: "inbox.query",
            highlightedID: highlighted.map { rows[$0].id },
            onMove: { inbox.move($0, among: rows.count) },
            onSubmit: {
                if let highlighted { model.openFromInbox(rows[highlighted].ref) }
            },
            onClose: model.closeInbox,
            rowsHeight: 520
        ) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                // A hairline between the sessions that need him, those that finished and the open session.
                if index > 0, rows[index - 1].mark != entry.mark {
                    PaletteDivider()
                }
                InboxRow(entry: entry, screen: screen(of: entry), catchUp: inbox.catchUps[entry.ref], isHighlighted: index == highlighted) {
                    model.openFromInbox(entry.ref)
                } askToCatchUp: {
                    if let link = model.link(for: entry.ref) { inbox.catchUp(on: entry, over: link) }
                }
                .id(entry.id)
            }
            if rows.isEmpty {
                Text(inbox.query.isEmpty ? "Nothing is waiting on you" : "No matching sessions")
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
                    .frame(maxWidth: .infinity, minHeight: Metrics.touch)
            }
        }
        .onChange(of: inbox.query) { inbox.highlighted = 0 }
        .onChange(of: model.showingPalette) { _, showing in
            if showing { model.closeInbox() }
        }
        .onChange(of: model.selection) { model.closeInbox() }
    }

    private func screen(of entry: InboxEntry) -> InboxRow.Screen {
        if let lines = inbox.lastLines[entry.ref] { return lines.isEmpty ? .blank : .lines(lines) }
        guard inbox.reading.contains(entry.ref) else { return .unread }
        return inbox.unreachable.contains(entry.ref.host) ? .unreachable(entry.host.phrase) : .reading
    }
}

/// A session: its program's icon, its name and whether it needs him or finished, what its program says,
/// and the last lines on its screen, with the button that asks for a summary and the summary under it.
private struct InboxRow: View {
    enum Screen {
        case reading
        case lines([String])
        /// Nothing with words on it.
        case blank
        case unreachable(String)
        /// It joined the inbox after the screens were read.
        case unread
    }

    @Environment(AppModel.self) private var model
    let entry: InboxEntry
    let screen: Screen
    let catchUp: CatchUp.State?
    let isHighlighted: Bool
    let open: () -> Void
    let askToCatchUp: () -> Void

    /// The program's icon, whose column the summary under the row keeps clear of.
    private static let icon: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.near) {
            HStack(alignment: .top, spacing: Metrics.near) {
                Button(action: open) {
                    HStack(alignment: .top, spacing: Metrics.near) {
                        ProgramIconView(command: entry.session.command, model: entry.session.model, size: Self.icon)
                        VStack(alignment: .leading, spacing: Metrics.tight) {
                            HStack(spacing: Metrics.near) {
                                Text(entry.ref.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if !detail.isEmpty {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.detail)
                                }
                                Spacer(minLength: 0)
                            }
                            .lineLimit(1)
                            // Under the session's name, so the message always says which session it came from.
                            if let message = entry.status?.message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.detail)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            ScreenLines(screen: screen)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inbox.\(entry.id)")
                .accessibilityValue(AttentionMark.label(entry.mark, status: entry.status))
                if catchUp?.canRetry ?? true {
                    Button(action: askToCatchUp) {
                        // The name's text style, its text level with the name's: a secondary button, neutral
                        // gray, its capsule reaching past the text.
                        Text(catchUp == nil ? "Catch Up" : "Try Again")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, Metrics.near)
                            .padding(.vertical, Metrics.tight)
                            .background(.fill.tertiary, in: .capsule)
                            .padding(.top, -Metrics.tight)
                            // The touch reaches a full 44 points.
                            .frame(minHeight: Metrics.touch, alignment: .top)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox.catchup.\(entry.id)")
                }
            }
            if let catchUp {
                Text(catchUp.text)
                    .font(.subheadline)
                    .foregroundStyle(catchUp.isWritten ? Color.primary : Theme.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.icon + Metrics.near)
                    .accessibilityIdentifier("inbox.summary.\(entry.id)")
            }
        }
        .padding(.vertical, Metrics.near)
        .paletteRow(isHighlighted: isHighlighted)
    }

    /// Whether the session needs him or finished, and its host when that is not the one on screen. Every
    /// row here is one he has not seen, so words tell them apart, not a mark. Nothing for the open
    /// session, pinned for its summary.
    private var detail: String {
        guard entry.mark != nil else { return "" }
        let state = AttentionMark.label(entry.mark)
        return entry.host.id == model.currentLink?.host.id ? state : "\(state) on \(entry.host.name)"
    }
}

/// The last lines on a session's screen, quoted in the terminal's font.
private struct ScreenLines: View {
    let screen: InboxRow.Screen
    /// The terminal font's size, which follows the text size as the notes' does.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12

    var body: some View {
        switch screen {
        case .lines(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(Font(TerminalFont.chosen.font(.regular, size: size)))
            .foregroundStyle(Theme.detail)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .reading:
            note("Reading its screen…")
        case .blank:
            note("Nothing on its screen")
        case .unreachable(let phrase):
            note("Can't reach \(phrase)")
        case .unread:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.detail)
    }
}

/// The strip's tray, there only while a session waits on him or finished while he was away: a tap opens
/// the inbox, and VoiceOver hears how many there are. Its text style comes from the bar it sits in.
struct InboxGlyph: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.inboxEntries
        if !entries.isEmpty {
            Button(action: model.toggleInbox) {
                Label("Inbox", systemImage: "tray.full")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox")
            .accessibilityValue("\(entries.count)")
        }
    }
}

extension Tmux {
    /// The named sessions' screens as text, in one exec: each after a record separator (0x1E, which no
    /// screen cell holds) and the session's name on a line of its own.
    static func screens(of sessions: [String]) -> String {
        prelude + sessions.map { name in
            #"printf '\036%s\n' \#(quote(name)); tmux capture-pane -p -J -t \#(quote("=" + name + ":")) 2>/dev/null"#
        }.joined(separator: "; ") + "; true"
    }

    /// The last `count` lines with words on each screen in `screens` output, by session name. Anything
    /// before the first separator, such as a login banner, is not a screen.
    static func lastLines(_ output: String, count: Int = 2) -> [String: [String]] {
        var screens: [String: [String]] = [:]
        for record in output.split(separator: "\u{1E}", omittingEmptySubsequences: false).dropFirst() {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard let name = lines.first, !name.isEmpty else { continue }
            screens[String(name)] = Array(lines.dropFirst().compactMap(words(in:)).suffix(count))
        }
        return screens
    }

    /// `line` without the blanks and box-drawing borders at either end and with each run of blanks inside
    /// cut to one space; nil when no letter or digit is left, as for a rule, a border or a bare prompt.
    static func words(in line: Substring) -> String? {
        func isEdge(_ character: Character) -> Bool {
            character.isWhitespace || character.unicodeScalars.allSatisfy { (0x2500...0x259F).contains($0.value) }
        }
        guard let first = line.firstIndex(where: { !isEdge($0) }), let last = line.lastIndex(where: { !isEdge($0) }),
              line[first...last].contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        var words = ""
        var blank = false
        for character in line[first...last] {
            if character.isWhitespace {
                blank = true
                continue
            }
            if blank { words.append(" ") }
            blank = false
            words.append(character)
        }
        return words
    }
}
