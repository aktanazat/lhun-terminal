import Foundation
import Observation
import OSLog
import SwiftTerm
import UIKit

/// One attached tmux session: its terminal view and the SSH channel feeding it.
///
/// It keeps the session attached. When the channel drops but tmux did not exit (the network went away,
/// the device slept, sshd restarted), it signs in again and reattaches to the same session. tmux redraws
/// the whole screen on attach, so nothing on it is lost, and the last screen stays up until that redraw
/// has all arrived. After a cold launch, the last screen is the one saved as Lhûn left (`show`).
@MainActor @Observable
final class TerminalModel {
    enum State: Equatable {
        case connecting
        case live
        case reconnecting
    }

    /// Who sets the session's size.
    enum Sizing: Equatable {
        /// This screen, as any tmux client does.
        case own
        /// Another screen with the session open; this one shows the window at that size.
        case watch(cols: Int, rows: Int)
    }

    let host: Host
    private(set) var name: String
    private(set) var state: State = .connecting
    /// Files on their way to the host from a paste or a drop.
    var uploads = 0
    /// Who sets the session's size. While another screen does, the card fits the window to itself rather
    /// than the other way round (SharedSize).
    private(set) var sizing: Sizing = .own
    /// Another screen that sets sizes has the session open too: the card offers Take or Give Back.
    private(set) var shared = false
    /// A chat card's terminal (SessionTerminal): it shows the window at whatever size the other screens
    /// give it and never sizes the session. It joins with tmux's `ignore-size` flag, opens its pty at the
    /// window's own size, follows the window through the share channel, and tells tmux no other size, so
    /// even when tmux counts it, as the only screen attached, the window keeps the size it has.
    @ObservationIgnored let watchesOnly: Bool

    /// The view lives as long as the session stays attached, so switching sessions keeps the screen and
    /// its connection instead of rebuilding them.
    @ObservationIgnored let view: LhunTerminalView
    /// The key row over the on-screen keyboard: one for every terminal (KeyRow).
    @ObservationIgnored let keyRow: KeyRow
    /// Called once tmux exits on its own: the session was killed or this client was detached.
    @ObservationIgnored var onEnded: (() -> Void)?
    /// Called when the session rings the terminal's bell.
    @ObservationIgnored var onBell: (() -> Void)?
    /// Told after each stretch of output reaches the screen, while history lies over it (HistoryView).
    @ObservationIgnored var onOutput: (() -> Void)?
    /// Told about everything the terminal sends tmux, typed or not, while history lies over it.
    @ObservationIgnored var onInput: ((ArraySlice<UInt8>) -> Void)?
    /// Called with the port when a link to the host's own localhost is opened, to preview it here.
    @ObservationIgnored var onPreview: ((Int) -> Void)?
    /// Called when a link is not opened because its target hides characters (`URL.hidesCharacters`).
    @ObservationIgnored var onBlockedLink: (() -> Void)?
    /// While set, typed keys and the terminal's replies come here first, and go on to tmux only when it
    /// returns false. The session peek reads its keys this way, so the terminal keeps the keyboard.
    @ObservationIgnored var keyTap: (([UInt8]) -> Bool)?
    /// Told when `sizing` changes, so the card fits the terminal again before tmux hears of it.
    @ObservationIgnored var onSizing: (() -> Void)?
    /// Told each time the session drops or an attach fails, before the wait to try again.
    @ObservationIgnored var onDropped: (() -> Void)?

    @ObservationIgnored private let key: DeviceKey
    @ObservationIgnored private let client: String
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var shell: ShellChannel?
    @ObservationIgnored private var attachLoop: Task<Void, Never>?
    @ObservationIgnored private var retryWait: Task<Void, Error>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var hasAttached = false
    @ObservationIgnored private(set) var fontSize: CGFloat = 0
    @ObservationIgnored private(set) var face = TerminalFont.xenon
    @ObservationIgnored private var sentSize = (cols: 0, rows: 0)
    /// While the app is in the background, iOS lays it out in the other orientation for the app switcher's
    /// picture; that grid is one nobody sees, so tmux gets no size until the app is back.
    @ObservationIgnored private var inBackground = false
    /// Bytes of output received from tmux, for the probe.
    @ObservationIgnored private(set) var bytesFed = 0
    /// Sizes sent to tmux after the first, for the probe.
    @ObservationIgnored private(set) var resizes = 0
    /// tmux redraws after an attach that have reached the screen, for the probe.
    @ObservationIgnored private(set) var redrawsShown = 0
    /// tmux's first redraw after an attach, held until all of it is in (`received`). Nil once fed.
    @ObservationIgnored private var redraw: RedrawHold?
    /// A saved screen is up, without its cursor until tmux's first redraw replaces it (`show`).
    @ObservationIgnored private var showsSaved = false
    /// Times keys on their way to the screen while the probe runs.
    @ObservationIgnored private let probe: Probe?
    /// Follows who else has the session open, while another screen does.
    @ObservationIgnored private var share: SharedSizeChannel?
    /// What the share channel reported last.
    @ObservationIgnored private var lastShare: SharedSize.Report?
    /// The share channel starts with the attach's first output, once the pid file names this client.
    @ObservationIgnored private var startsShare = false
    /// tmux has yet to answer a change to this client's flags.
    @ObservationIgnored private var flagging = false
    /// Looking at whether a client that just came to the session sets sizes.
    @ObservationIgnored private var joinCheck: Task<Void, Never>?
    /// The share channel started because another screen came while this one set the size: its first
    /// report hands the size over, even when a resize from here since made tmux size for this screen.
    @ObservationIgnored private var joinedLater = false
    /// Typed keys drawn ahead of their echo while the echo is slow (EchoPrediction), and the timeout of its
    /// oldest guess, armed for that guess's deadline.
    @ObservationIgnored private(set) var prediction = EchoPrediction()
    @ObservationIgnored private var predictionDeadline: (at: TimeInterval, work: DispatchWorkItem)?
    /// The pane on screen is on the alternate screen, as the host's watcher last reported (AppModel): a
    /// full-screen program, where keys are not echoed at the cursor. tmux keeps the terminal itself on the
    /// alternate screen all the while, so only the watcher can tell.
    @ObservationIgnored var alternateScreen = false

    /// tmux owns history, and Lhûn reads it from tmux when you scroll back (HistoryView), so the view keeps
    /// no scrollback of its own. Images are capped well below SwiftTerm's default too. Colors 16 to 255 are
    /// xterm's, as history and the session pictures draw them (`Theme.Palette.hex`), not SwiftTerm's default
    /// blend of them toward the theme, which dulled them on the live screen alone.
    static let options = TerminalOptions(
        cursorStyle: .steadyBar,
        scrollback: 0,
        kittyImageCacheLimitBytes: 32 * 1024 * 1024,
        ansi256PaletteStrategy: .xterm
    )

    /// Draws with Metal only while on screen. A hidden terminal gives back its Metal view, renderer and
    /// glyph textures, and builds them again when shown; its screen contents stay.
    func setVisible(_ visible: Bool) {
        guard visible != view.isUsingMetalRenderer else { return }
        do {
            if visible, let probe {
                try probe.measureRenderer { try view.setUseMetal(true) }
            } else {
                try view.setUseMetal(visible)
            }
        } catch {
            Self.log.error("Metal is unavailable, drawing with Core Graphics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The app went to the background, or came back: back, tmux gets the size the terminal has then.
    func setInBackground(_ away: Bool) {
        inBackground = away
        if !away { resizeIfNeeded() }
    }

    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "terminal")
    /// Seconds to wait before each retry; the last one repeats.
    private static let retryDelays: [Double] = [0, 1, 2, 4, 8]

    init(
        host: Host, name: String, key: DeviceKey, client: String, fontSize: CGFloat, face: TerminalFont, keyRow: KeyRow, probe: Probe?,
        watchesOnly: Bool
    ) {
        self.host = host
        self.name = name
        self.key = key
        self.client = client
        self.probe = probe
        self.watchesOnly = watchesOnly
        view = LhunTerminalView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            options: Self.options
        )
        self.keyRow = keyRow
        view.terminalDelegate = self
        view.accessibilityIdentifier = "terminal"
        setFont(size: fontSize, face: face)
        if let probe {
            view.onKeyDown = { pressed in probe.keyDown(at: pressed) }
            view.onKeyText = { directly in probe.keyInserted(directly: directly) }
        }
    }

    var ref: SessionRef { SessionRef(host: host.id, name: name) }

    /// The size of one character cell in points at the current font.
    var cellSize: CGSize {
        let terminal = view.getTerminal()
        let grid = view.getOptimalFrameSize().size
        return CGSize(width: grid.width / CGFloat(terminal.cols), height: grid.height / CGFloat(terminal.rows))
    }

    /// Ports of the localhost addresses on screen, top to bottom. A line the terminal wrapped is read
    /// joined to the line before it, so a long address split across rows still counts.
    var screenPorts: [Int] {
        let terminal = view.getTerminal()
        var text = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            if row > 0, !line.isWrapped { text += "\n" }
            text += line.translateToString(trimRight: true)
        }
        return LocalURL.ports(in: text)
    }

    /// Types text at the cursor the way a paste does, so the program reading it knows it was pasted:
    /// Claude Code, for one, attaches an image whose path is pasted. What could run as keys is made safe
    /// first (Paste).
    func paste(_ text: String) {
        view.send(Paste.bytes(text, bracketed: view.getTerminal().bracketedPasteMode))
    }

    /// Whether the program in the session's active pane takes a paste as one piece (bracketed paste). The
    /// view's own flag cannot tell: tmux keeps bracketed paste on with this device whatever the program
    /// asked, and takes the markers off for one that did not, whose lines then each run. False when tmux
    /// could not be asked.
    func paneTakesPastes() async -> Bool {
        guard let reply = try? await run(Tmux.takesPastes(name)) else { return false }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// What the screen shows now, to show again after a cold launch.
    var savedScreen: SavedScreen {
        SavedScreen(of: view.getTerminal(), watched: sizing != .own)
    }

    /// Shows a saved screen at the grid it was saved at, before the first attach, so the card is readable
    /// while Lhûn signs in. A grid another screen set shows smaller to fit, as it did, until the attach
    /// learns who sets the size now. tmux's first redraw replaces the screen in a single frame, as it
    /// replaces the last screen after a drop (`received`), and brings the cursor back.
    func show(_ saved: SavedScreen) {
        if saved.watched { setSizing(.watch(cols: saved.cols, rows: saved.rows)) }
        view.resize(cols: saved.cols, rows: saved.rows)
        view.feed(byteArray: [UInt8](saved.bytes)[...])
        showsSaved = true
    }

    func start() {
        guard attachLoop == nil else { return }
        attachLoop = Task { await keepAttached() }
    }

    /// Leaves the session running on the host and lets go of it here.
    func detach() {
        attachLoop?.cancel()
        attachLoop = nil
        retryWait?.cancel()
        joinCheck?.cancel()
        stopShare()
        shell?.close()
        shell = nil
        connection?.close()
        connection = nil
    }

    func rename(to newName: String) {
        name = newName
    }

    /// Checks the connection after the app comes back or the network changes. A connection can look open
    /// long after the path under it is gone; a one-word command settles it within seconds. A session
    /// waiting to retry tries again now instead of sitting out its delay.
    func verify() async {
        guard state == .live, let connection else {
            retryWait?.cancel()
            return
        }
        do {
            _ = try await connection.run("true", timeout: .seconds(4))
        } catch {
            connection.close()
        }
    }

    /// Returns whether the size or face changed. The host fits the grid again when it did.
    @discardableResult
    func setFont(size: CGFloat, face: TerminalFont) -> Bool {
        guard size != fontSize || face != self.face else { return false }
        fontSize = size
        self.face = face
        let fonts = Theme.terminalFonts(size: size, font: face)
        view.setFonts(normal: fonts.regular, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
        return true
    }

    /// Runs a command on the session's host over its connection.
    func run(_ command: String) async throws -> String {
        guard state == .live, let connection else { throw SSHFailure.closed }
        return try await connection.run(command, timeout: .seconds(10))
    }

    private func keepAttached() async {
        while !Task.isCancelled {
            do {
                let shell = try await attach()
                let end = await shell.end()
                self.shell = nil
                stopShare()
                if Task.isCancelled { return }
                if case .exited(let status) = end {
                    Self.log.info("tmux left \(self.name, privacy: .public) with status \(status)")
                    // tmux's last words, such as a session it could not find, still reach the screen.
                    releaseRedraw(showing: true)
                    attachLoop = nil
                    connection?.close()
                    connection = nil
                    onEnded?()
                    return
                }
            } catch {
                Self.log.info("Attach to \(self.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                connection?.close()
                connection = nil
            }
            if Task.isCancelled { return }
            // Half a redraw is worse than the last screen, which stays up while Lhûn reconnects.
            releaseRedraw(showing: false)
            dropPrediction()
            if state == .live { probe?.connectionDropped(self) }
            state = .reconnecting
            failures += 1
            onDropped?()
            await waitBeforeRetry()
        }
    }

    private func attach() async throws -> ShellChannel {
        let connection = try await currentConnection()
        if hasAttached {
            // CAN: drop any escape sequence the old connection cut off halfway, before tmux redraws.
            view.feed(byteArray: [0x18])
        }
        // A screen that already has the session open keeps its size: this one joins without taking it, and
        // the card fits the window before the first size goes to tmux. A chat card always joins that way,
        // at the window's own size, whoever else has the session open.
        let size: (cols: Int, rows: Int)
        let ignoringSize: Bool
        if watchesOnly {
            let window = SharedSize.window(in: try await connection.run(SharedSize.windowQuery(name), timeout: .seconds(10)))
            if let window { setSizing(.watch(cols: window.cols, rows: window.rows)) }
            startsShare = true
            ignoringSize = true
            let terminal = view.getTerminal()
            size = window ?? (cols: terminal.cols, rows: terminal.rows)
        } else {
            let others = SharedSize.othersWindow(
                in: try await connection.run(SharedSize.query(name, client: client), timeout: .seconds(10))
            )
            setSizing(others.map { Sizing.watch(cols: $0.cols, rows: $0.rows) } ?? .own)
            startsShare = others != nil
            ignoringSize = others != nil
            let terminal = view.getTerminal()
            size = (cols: terminal.cols, rows: terminal.rows)
        }
        redraw = RedrawHold()
        // The probe can have this attach's output stall partway, as a slow link would (OutputStall).
        let stall = probe?.outputStall()
        let relay = OutputRelay(timesArrivals: probe != nil) { [weak self] bytes, arrivals in
            guard let self else { return }
            for arrived in arrivals { probe?.outputArrived(at: arrived) }
            if let stall {
                stall.pass(bytes) { [weak self] in self?.received($0) }
            } else {
                received(bytes)
            }
            // tmux draws, so this client has written its pid file.
            if startsShare { startShare() }
        }
        let shell = try await connection.openShell(
            command: Tmux.attach(name, client: client, ignoringSize: ignoringSize),
            cols: size.cols,
            rows: size.rows,
            output: { bytes in relay.append(bytes) }
        )
        hasAttached = true
        self.shell = shell
        sentSize = size
        state = .live
        failures = 0
        probe?.attached(self)
        // The view may have changed size while the channel was opening.
        resizeIfNeeded()
        return shell
    }

    /// Output from tmux. After an attach it is held until all of tmux's first redraw is in, then fed at
    /// once, so the screen goes from the last one shown to the redrawn one in a single frame instead of
    /// clearing first and filling in as the bytes arrive (RedrawHold). tmux's questions about the terminal
    /// go to it as they arrive, so the answers reach tmux in time.
    private func received(_ bytes: [UInt8]) {
        bytesFed += bytes.count
        guard let step = redraw?.take(bytes) else { return feed(bytes[...]) }
        for question in step.questions { view.feed(byteArray: question[...]) }
        if step.redrawn { releaseRedraw(showing: true) }
    }

    /// Stops holding output, feeding what was held or dropping it.
    private func releaseRedraw(showing: Bool) {
        guard let held = redraw?.held else { return }
        redraw = nil
        if showing, !held.isEmpty {
            if showsSaved {
                showsSaved = false
                view.feed(byteArray: Array("\u{1B}[?25h".utf8)[...])
            }
            feed(held[...])
            redrawsShown += 1
        }
    }

    private func feed(_ bytes: ArraySlice<UInt8>) {
        view.feed(byteArray: bytes)
        let terminal = view.getTerminal()
        // Midway through a synchronized update the screen is half drawn, and none of it shows yet.
        if prediction.isGuessing, !terminal.synchronizedOutputActive {
            prediction.check(terminal, at: CACurrentMediaTime())
            showPrediction(afterOutput: true)
        }
        onOutput?()
    }

    /// Draws what local echo shows now, and arms the timeout of its oldest guess.
    private func showPrediction(afterOutput: Bool) {
        view.showPrediction(prediction.shown, afterOutput: afterOutput)
        let deadline = prediction.deadline
        guard deadline != predictionDeadline?.at else { return }
        predictionDeadline?.work.cancel()
        predictionDeadline = nil
        guard let deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.predictionTimedOut() }
        }
        predictionDeadline = (deadline, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline - CACurrentMediaTime(), 0), execute: work)
    }

    private func predictionTimedOut() {
        predictionDeadline = nil
        prediction.expire(at: CACurrentMediaTime())
        showPrediction(afterOutput: false)
    }

    /// Takes every guess off the screen at once: the connection or the grid changed under them.
    private func dropPrediction() {
        guard prediction.isGuessing else { return }
        prediction.drop()
        showPrediction(afterOutput: false)
    }

    private func currentConnection() async throws -> SSHConnection {
        if let connection, connection.isActive { return connection }
        let fresh = try await SSHConnection.open(to: host, key: key.privateKey)
        connection = fresh
        return fresh
    }

    private func waitBeforeRetry() async {
        let seconds = Self.retryDelays[min(failures, Self.retryDelays.count) - 1]
        guard seconds > 0 else { return }
        let wait = Task { try await Task.sleep(for: .seconds(seconds)) }
        retryWait = wait
        _ = await wait.result
        retryWait = nil
    }

    private func resizeIfNeeded() {
        let terminal = view.getTerminal()
        let grid = (cols: terminal.cols, rows: terminal.rows)
        guard !inBackground, let shell, grid != sentSize else { return }
        // A chat card tells tmux only the window's own size, once its grid has it.
        if watchesOnly, sizing != .watch(cols: grid.cols, rows: grid.rows) { return }
        sentSize = grid
        shell.resize(cols: grid.cols, rows: grid.rows)
        resizes += 1
    }

    // MARK: Sharing the size

    /// Makes this screen's size the session's, on every screen that has it open.
    func takeSize() {
        guard case .watch = sizing, shared else { return }
        setIgnoresSize(false) { $0.setSizing(.own) }
    }

    /// Lets the other screen that has the session open size it again; this one shows its window.
    func giveBackSize() {
        guard sizing == .own, shared, let other = lastShare?.latestOther else { return }
        setIgnoresSize(true) { $0.setSizing(.watch(cols: other.cols, rows: other.rows)) }
    }

    /// A client came to the session (the host's watcher heard it). When it sets sizes, this screen leaves
    /// the size to it, as it does when it finds one already there.
    func clientJoined() {
        guard state == .live, share == nil, !startsShare, joinCheck == nil, let connection else { return }
        joinCheck = Task {
            defer { joinCheck = nil }
            let output = try? await connection.run(SharedSize.query(name, client: client), timeout: .seconds(10))
            guard let output, SharedSize.othersWindow(in: output) != nil, shell != nil, share == nil else { return }
            joinedLater = true
            startShare()
        }
    }

    private func setSizing(_ next: Sizing) {
        guard next != sizing else { return }
        sizing = next
        onSizing?()
    }

    private func startShare() {
        startsShare = false
        guard share == nil, let connection, connection.isActive else { return }
        let channel = SharedSizeChannel(
            reported: { [weak self] in self?.shareReported($0) },
            ended: { [weak self] in self?.shareEnded($0) }
        )
        share = channel
        channel.start(on: connection, session: name, client: client)
    }

    private func stopShare() {
        startsShare = false
        joinedLater = false
        share?.stop()
        share = nil
        lastShare = nil
        shared = false
    }

    private func shareReported(_ report: SharedSize.Report) {
        // A chat card follows the window, whoever sizes it, and never takes or gives back the size.
        if watchesOnly { return setSizing(.watch(cols: report.windowCols, rows: report.windowRows)) }
        lastShare = report
        shared = !report.others.isEmpty
        guard !flagging else { return }
        if joinedLater, sizing == .own, report.own != nil, let other = report.latestOther {
            joinedLater = false
            setIgnoresSize(true) { $0.setSizing(.watch(cols: other.cols, rows: other.rows)) }
            return
        }
        switch SharedSize.step(watching: sizing != .own, sent: sentSize, report: report) {
        case .stay:
            break
        case .watch(let cols, let rows):
            setSizing(.watch(cols: cols, rows: rows))
        case .take:
            setIgnoresSize(false) { model in
                model.setSizing(.own)
                model.stopShare()
            }
        case .yield(let cols, let rows):
            setIgnoresSize(true) { $0.setSizing(.watch(cols: cols, rows: rows)) }
        case .alone:
            stopShare()
        }
    }

    /// Without the channel nothing tells when the other screen leaves: the window stays as it is until
    /// the session attaches again.
    private func shareEnded(_ channel: SharedSizeChannel) {
        guard channel === share else { return }
        joinedLater = false
        share = nil
        lastShare = nil
        shared = false
    }

    /// Sets or clears tmux's `ignore-size` flag on this screen's client, and once tmux has, goes on with
    /// `then`. A screen that takes the size refits at once, and that resize makes it the one tmux sizes for.
    private func setIgnoresSize(_ ignore: Bool, then: @escaping (TerminalModel) -> Void) {
        guard !flagging, let share, let own = lastShare?.own else { return }
        flagging = true
        share.setIgnoresSize(ignore, client: own.name) { [weak self] done in
            guard let self else { return }
            flagging = false
            if done { then(self) }
        }
    }
}

extension TerminalModel: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let keyTap, keyTap(Array(data)) { return }
        onInput?(data)
        // Keys typed before the session is live are dropped rather than replayed into a screen that may
        // have changed since.
        guard state == .live, let shell else { return }
        shell.write(Array(data))
        view.wakeCursor()
        probe?.keySent(data)
        let shown = prediction.counts.shown
        let guessable = !alternateScreen && view.cursorShown
        prediction.sent(data, at: CACurrentMediaTime(), on: view.getTerminal(), guessable: guessable)
        showPrediction(afterOutput: false)
        if prediction.counts.shown > shown { probe?.guessShown() }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        dropPrediction()
        resizeIfNeeded()
    }

    /// A link to the host's own localhost opens in the preview: in Safari it would mean the iPad. One whose
    /// target hides characters does not open at all.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard !URL.hidesCharacters(link) else {
            onBlockedLink?()
            return
        }
        guard let url = URL(webLink: link) else { return }
        if let port = LocalURL.port(of: url), let onPreview {
            onPreview(port)
        } else {
            UIApplication.shared.open(url)
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }

    /// SwiftTerm's own answer to a bell is a haptic; keep it, and tell the session marks.
    func bell(source: TerminalView) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        onBell?()
    }

    /// Programs on the host never get to read this device's clipboard.
    func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    // tmux owns titles, the working directory and scrollback, so the view's reports of them go unused.
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The terminal as local echo reads it (EchoPrediction).
extension Terminal: EchoScreen {
    var cursorCol: Int { getCursorLocation().x }
    var cursorRow: Int { getCursorLocation().y }

    func byte(col: Int, row: Int) -> UInt8? {
        guard let character = getCharacter(col: col, row: row) else { return nil }
        if character == "\0" { return 0x20 }
        guard let ascii = character.asciiValue, (0x20...0x7E).contains(ascii) else { return nil }
        return ascii
    }
}
