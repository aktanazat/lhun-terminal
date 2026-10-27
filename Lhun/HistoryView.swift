import OSLog
import SwiftTerm
import UIKit

/// tmux's history laid over a terminal, read in as you swipe back through it, or the screen itself laid
/// over it to select on.
///
/// A swipe down on a terminal whose program has not asked for the mouse reads the last 500 lines of the
/// session's active pane, colors included, in one exec, and lays them over the terminal in its own
/// cells, fonts and colors, so nothing on screen moves as the overlay appears. From then on it is a
/// native text view: it follows the swipe with momentum, reads 2,000 older lines each time you near the
/// top, and its text can be selected and copied here. Find reads all retained history before searching.
///
/// It goes away, with everything it read, when you scroll back to the bottom, type, or new lines move
/// the screen. Output that only redraws part of the screen, such as a spinner or a clock, leaves it
/// open.
///
/// A long press lays the screen as the terminal holds it over the terminal the same way, nothing read,
/// and selects the word under the finger, then on to wherever it drags; the selection, its handles and
/// its menu are history's. That goes away too once a tap clears the selection.
///
/// A copy flashes what it copied. With Copy on Select on, a selection is copied as the finger that made
/// it lifts, the long press's or the one that moved a handle.
final class HistoryView: UITextView, UITextViewDelegate {
    /// Told once it has closed, so the host lets go of it.
    var onClose: (() -> Void)?
    /// Sends the selected text to the app embedding LhunKit, from the menu over the selection
    /// (`Lhun.onAskAkyl`); nil, the menu does not offer it.
    var askAkyl: ((String) -> Void)?

    /// The last one opened, while anything still holds it. The probe reports it: once one closes,
    /// nothing should.
    private(set) static weak var latest: HistoryView?

    private static let firstLines = 500
    private static let moreLines = 2000
    /// How fast a swipe's momentum fades: UIScrollView's own rate, the share of speed kept each millisecond.
    private static let deceleration = Double(UIScrollView.DecelerationRate.normal.rawValue)
    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "history")

    private let terminal: TerminalModel
    private let layout: HistoryText.Layout
    private var style: HistoryText.Style
    /// The screen's first line with anything on it, as the overlay opened (`TopLine`).
    private var screenTop: TopLine?
    private var reading: Task<Void, Never>?
    /// The pane's history size and width when the overlay opened. A change means the lines moved.
    private var historySize = 0
    private var paneWidth = 0
    /// tmux's number for the line in the top row: the screen starts at 0 and history counts back from -1.
    private var top = 0
    /// The top row's characters: the next older stretch ends with them.
    private var topRow = ""
    private var rowCount = 0
    private var closed = false
    /// The slowest older stretch so far, from its reply to its rows laid out, in milliseconds.
    private var slowestRead = 0

    /// The host's swipe that opened the overlay, followed until the finger lifts.
    private weak var swipe: UIPanGestureRecognizer?
    /// How far that swipe has moved down, and its speed when it lifted while the text was still on its way.
    private var swipeTravel: CGFloat = 0
    private var released: CGFloat?
    /// The offset the swipe's travel is taken from: the bottom, as the text arrived.
    private var swipeStart: CGFloat = 0
    private var fling: CADisplayLink?
    /// Points per second, positive toward the bottom.
    private var flingSpeed: CGFloat = 0
    private var flingTime: CFTimeInterval = 0
    private var findWhenShown = false
    private var promptWhenShown: Int?
    private var navigation: Task<Void, Never>?
    private var navigationStatus: UIView?
    private var promptRows: [Int]?
    private var highlightedPrompt: Int?
    /// Who had the keys when the find bar opened: the terminal, with its keyboard and key row, or this.
    private weak var keysBeforeFind: UIResponder?
    /// Whether the overlay shows the screen as it is, laid over to select on, rather than history.
    private(set) var isScreen = false
    /// The long press that laid the screen over, followed until the finger lifts, and the word it began on.
    private weak var press: UILongPressGestureRecognizer?
    private var pressedWord = NSRange()
    /// Whether the screen has had something selected; clearing that takes the screen away.
    private var hadSelection = false
    private var menu: UIEditMenuInteraction?
    /// The selection last copied, so a tap that leaves it as it was copies nothing again.
    private var copied: NSRange?
    /// Whether the terminal under the overlay is hidden, having given back what it draws with.
    private var covering = false

    init(terminal: TerminalModel, palette: Theme.Palette) {
        self.terminal = terminal
        let fonts = Theme.terminalFonts(size: terminal.fontSize, font: terminal.face)
        let cell = terminal.cellSize
        layout = HistoryText.Layout(cell: cell, font: fonts.regular)
        style = HistoryText.Style(cell: cell, fonts: fonts, palette: palette)
        super.init(frame: .zero, textContainer: layout.container)
        isEditable = false
        isFindInteractionEnabled = false
        textContainerInset = .zero
        contentInsetAdjustmentBehavior = .never
        backgroundColor = Theme.uiColor(palette.background)
        indicatorStyle = palette.isLight ? .black : .white
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        isHidden = true
        delegate = self
        accessibilityIdentifier = "history"
        // One element holding the text, as the terminal under it is. Left as a container, UIKit makes an
        // element of every line and scans the whole text for links once per line, holding the main thread
        // about 4 seconds at 500 lines and over 30 at 2,500 whenever VoiceOver or a UI test looks.
        isAccessibilityElement = true
        Self.latest = self
        addGestureRecognizer(LiftWatcher { [weak self] in self?.lifted() })
    }

    required init?(coder: NSCoder) {
        fatalError("HistoryView is built in code")
    }

    /// For the probe: rows held, rows between the bottom of the view and the newest line, the slowest older
    /// stretch, and whether the find bar shows.
    var measurements: [String: Any] {
        let back = rowCount == 0 ? 0 : Int(((bottomOffset - contentOffset.y) / style.cell.height).rounded())
        let finding = findInteraction?.isFindNavigatorVisible == true
        return [
            "rows": rowCount, "back": back, "slowestRead": slowestRead, "closed": closed, "finding": finding,
            "loadingHistory": navigation != nil, "promptRows": promptRows?.count ?? 0,
        ]
    }

    /// Starts reading. `swipe` is the host's swipe that asked for history, which the text follows from when
    /// it arrives. Without one, as for ⌘F, the overlay opens at the bottom with the find bar up.
    func open(following swipe: UIPanGestureRecognizer?, promptStep: Int? = nil) {
        self.swipe = swipe
        promptWhenShown = promptStep
        findWhenShown = swipe == nil && promptStep == nil
        screenTop = TopLine(terminal.view.getTerminal())
        terminal.onOutput = { [weak self] in self?.outputArrived() }
        terminal.onInput = { [weak self] bytes in self?.inputSent(bytes) }
        reading = Task { [weak self] in
            await self?.readNewest()
            self?.reading = nil
        }
    }

    /// Moves with the swipe that opened the overlay, and carries its momentum on once the finger lifts.
    func follow(_ pan: UIPanGestureRecognizer) {
        guard pan === swipe, let host = superview else { return }
        swipeTravel = pan.translation(in: host).y
        switch pan.state {
        case .changed:
            if !isHidden { contentOffset.y = clamped(swipeStart - swipeTravel) }
        case .ended:
            swipe = nil
            let speed = -pan.velocity(in: host).y
            released = speed
            if !isHidden { startFling(speed) }
        case .cancelled, .failed:
            swipe = nil
            released = 0
            if !isHidden { settle() }
        default:
            break
        }
    }

    /// Lays the screen over the terminal as the terminal holds it and selects the word under a long press,
    /// or nothing when the finger is not on a word.
    func select(from press: UILongPressGestureRecognizer) {
        isScreen = true
        self.press = press
        accessibilityIdentifier = "selection"
        // ⌘F searches history, which the host lays over instead of this.
        isFindInteractionEnabled = false
        let screen = terminal.view.getTerminal()
        screenTop = TopLine(screen)
        terminal.onOutput = { [weak self] in self?.outputArrived() }
        terminal.onInput = { [weak self] bytes in self?.inputSent(bytes) }
        let rows = HistoryText.Rows(screen: screen)
        layout.storage.setAttributedString(style.text(rows, endingWith: nil))
        rowCount = rows.rows.count
        show()
        _ = becomeFirstResponder()
        pressedWord = word(at: press.location(in: self))
        selectedRange = pressedWord
    }

    /// Moves the selection with the long press that laid the screen over: from the word it began on to
    /// the character under the finger. The menu shows once the finger lifts.
    func follow(_ press: UILongPressGestureRecognizer) {
        guard press === self.press else { return }
        switch press.state {
        case .changed:
            selectedRange = selection(to: press.location(in: self))
        case .ended:
            self.press = nil
            hadSelection = selectedRange.length > 0
            if hadSelection, terminal.view.copyOnSelect { copy(nil) }
            showMenu(at: press.location(in: self))
        case .cancelled, .failed:
            self.press = nil
            hadSelection = selectedRange.length > 0
            if !hadSelection { close() }
        default:
            break
        }
    }

    /// Opens the find bar only once all retained history is searchable.
    func find() {
        guard !closed, !isScreen, navigation == nil else { return }
        let query = selectedRange.length > 0
            ? (layout.storage.string as NSString).substring(with: selectedRange) : nil
        if top <= -historySize, !isHidden {
            presentFind(query: query)
        } else {
            prepareNavigation { [weak self] in self?.presentFind(query: query) }
        }
    }

    private func presentFind(query: String?) {
        clearNavigationStatus()
        highlightedPrompt = nil
        isFindInteractionEnabled = true
        if let query { findInteraction?.searchText = query }
        if keysBeforeFind == nil {
            keysBeforeFind = terminal.view.isFirstResponder ? terminal.view : self
            NotificationCenter.default.addObserver(
                self, selector: #selector(findFieldEnded), name: UITextField.textDidEndEditingNotification, object: nil
            )
        }
        _ = becomeFirstResponder()
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func stepPrompt(_ step: Int, fromBottom: Bool = false) {
        guard !closed, !isScreen, navigation == nil else { return }
        let row = fromBottom ? top + rowCount
            : highlightedPrompt ?? top + Int((contentOffset.y / style.cell.height).rounded(.down))
        prepareNavigation { [weak self] in
            await self?.showPrompt(step, relativeTo: row)
        }
    }

    private func prepareNavigation(_ action: @escaping @MainActor () async -> Void) {
        stopFling()
        showNavigationStatus("Loading history", loading: true)
        navigation = Task { [weak self] in
            guard let self else { return }
            if let reading { await reading.value }
            while !closed, !Task.isCancelled, top > -historySize {
                await readOlder()
                await Task.yield()
            }
            guard !closed, !Task.isCancelled else { return }
            await action()
            guard !closed, !Task.isCancelled else { return }
            navigation = nil
        }
    }

    private func showPrompt(_ step: Int, relativeTo row: Int) async {
        if promptRows == nil {
            do {
                let output = try await terminal.run(Tmux.historyPrompts(terminal.name))
                guard !closed, !Task.isCancelled else { return }
                guard let prompts = HistoryText.Prompts(output),
                      prompts.history == historySize, prompts.width == paneWidth else {
                    close()
                    return
                }
                promptRows = prompts.rows
            } catch {
                guard !closed, !Task.isCancelled else { return }
                Self.log.info("Reading prompt markers failed: \(error.localizedDescription, privacy: .public)")
                showNavigationStatus("Couldn’t read prompt markers", loading: false)
                return
            }
        }
        guard let promptRows, !promptRows.isEmpty else {
            showNavigationStatus("No prompt markers", loading: false)
            return
        }
        let target = step < 0 ? promptRows.last { $0 < row } : promptRows.first { $0 > row }
        guard let target else {
            showNavigationStatus(step < 0 ? "No earlier prompt" : "No newer prompt", loading: false)
            return
        }
        clearNavigationStatus()
        highlightedPrompt = target
        contentOffset.y = clamped(CGFloat(target - top) * style.cell.height)
    }

    private func showNavigationStatus(_ message: String, loading: Bool) {
        clearNavigationStatus()
        guard let host = superview else { return }
        let status = UIStackView()
        status.axis = .horizontal
        status.spacing = Metrics.near
        status.isLayoutMarginsRelativeArrangement = true
        status.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: Metrics.near, bottom: 0, trailing: 0)
        status.backgroundColor = backgroundColor
        if loading {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = terminal.view.nativeForegroundColor
            spinner.startAnimating()
            status.addArrangedSubview(spinner)
        }
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = terminal.view.nativeForegroundColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.addArrangedSubview(label)
        let dismiss = UIButton(type: .system)
        dismiss.setTitle(loading ? "Cancel" : "Done", for: .normal)
        dismiss.tintColor = terminal.view.nativeForegroundColor
        dismiss.addTarget(self, action: #selector(cancelNavigation), for: .touchUpInside)
        dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.addArrangedSubview(dismiss)
        status.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(status)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: topAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.touch),
            dismiss.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.touch),
            dismiss.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.touch),
        ])
        navigationStatus = status
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func clearNavigationStatus() {
        navigationStatus?.removeFromSuperview()
        navigationStatus = nil
    }

    @objc private func cancelNavigation() {
        navigation?.cancel()
        navigation = nil
        clearNavigationStatus()
    }

    /// The find bar's field gives up the keys as the bar closes, and nothing takes them after it. Once the
    /// bar has gone, they go back to whoever had them before it opened.
    @objc private func findFieldEnded() {
        Task { @MainActor [weak self] in
            guard let self, !closed, findInteraction?.isFindNavigatorVisible != true, let keys = keysBeforeFind else { return }
            keysBeforeFind = nil
            NotificationCenter.default.removeObserver(self, name: UITextField.textDidEndEditingNotification, object: nil)
            _ = keys.becomeFirstResponder()
        }
    }

    /// Takes the overlay away and lets go of everything it read; the terminal under it is live again.
    func close() {
        guard !closed else { return }
        closed = true
        reading?.cancel()
        reading = nil
        cancelNavigation()
        stopFling()
        terminal.onOutput = nil
        terminal.onInput = nil
        menu?.dismissMenu()
        let focused = isFirstResponder || findInteraction?.isFindNavigatorVisible == true
        findInteraction?.dismissFindNavigator()
        if covering {
            uncover()
        } else {
            leave()
        }
        if focused { _ = terminal.view.becomeFirstResponder() }
        onClose?()
        onClose = nil
    }

    // MARK: Reading

    private func readNewest() async {
        guard let read = await read(from: -Self.firstLines, to: nil),
              read.history > 0 || findWhenShown || promptWhenShown != nil else {
            close()
            return
        }
        historySize = read.history
        paneWidth = read.width
        top = -min(Self.firstLines, read.history)
        let rows = HistoryText.Rows(read.capture, width: read.width)
        guard let first = rows.rows.first else {
            close()
            return
        }
        layout.storage.setAttributedString(style.text(rows, endingWith: nil))
        rowCount = rows.rows.count
        topRow = HistoryText.Rows.text(of: first)
        show()
    }

    /// Reads the next older stretch while more than three screens are left to scroll through.
    private func readOlderIfNear() {
        guard !isHidden, !closed, reading == nil, navigation == nil,
              top > -historySize, contentOffset.y < bounds.height * 3 else { return }
        reading = Task { [weak self] in
            await self?.readOlder()
            self?.reading = nil
        }
    }

    private func readOlder() async {
        let start = max(top - Self.moreLines, -historySize)
        guard let read = await read(from: start, to: top) else {
            if !Task.isCancelled { close() }
            return
        }
        // New lines renumber all of history, so this stretch would not end where the text begins.
        guard read.history == historySize, read.width == paneWidth else {
            close()
            return
        }
        let began = CACurrentMediaTime()
        var rows = HistoryText.Rows(read.capture, width: read.width)
        guard rows.rows.last.map(HistoryText.Rows.text(of:)) == topRow else {
            close()
            return
        }
        let wraps = rows.dropLast(matching: topRow)
        top = start
        guard let first = rows.rows.first else { return }
        prepend(style.text(rows, endingWith: wraps ? HistoryText.wrap : HistoryText.lineEnd), rows: rows.rows.count)
        topRow = HistoryText.Rows.text(of: first)
        slowestRead = max(slowestRead, Int(((CACurrentMediaTime() - began) * 1000).rounded()))
    }

    /// One exec: the pane's history size and width, then its lines from `start` to `end`, or to the bottom
    /// of the screen without one. Nil once closed, or when the host could not be asked.
    private func read(from start: Int, to end: Int?) async -> (history: Int, width: Int, capture: Substring)? {
        guard !closed, !Task.isCancelled else { return nil }
        let output: String
        do {
            output = try await terminal.run(Tmux.history(terminal.name, from: start, to: end))
        } catch {
            Self.log.info("Reading history failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard !closed, !Task.isCancelled, let newline = output.firstIndex(of: "\n") else { return nil }
        let header = output[..<newline].split(separator: " ")
        guard header.count == 2, let history = Int(header[0]), let width = Int(header[1]) else { return nil }
        return (history, width, output[output.index(after: newline)...])
    }

    /// Lays the text over the terminal, scrolled to where the swipe has got to.
    private func show() {
        isHidden = false
        // The overlay covers the terminal whole. Hidden under it, the terminal gives back its Metal view,
        // renderer and glyph textures (TerminalModel.setVisible), and draws again as the overlay goes.
        covering = true
        terminal.view.isHidden = true
        terminal.setVisible(false)
        layout.manager.ensureLayout(for: layout.container)
        fitContent()
        swipeStart = bottomOffset
        contentOffset.y = clamped(swipeStart - swipeTravel)
        if let promptWhenShown {
            stepPrompt(promptWhenShown, fromBottom: true)
        } else if findWhenShown {
            find()
        } else if let released {
            // The finger lifted while the text was on its way.
            startFling(released)
        }
    }

    /// Puts older rows above the text without moving what is on screen.
    private func prepend(_ text: NSAttributedString, rows: Int) {
        let selection = selectedRange
        let shift = CGFloat(rows) * style.cell.height
        layout.storage.insert(text, at: 0)
        rowCount += rows
        layout.manager.ensureLayout(for: layout.container)
        fitContent()
        contentOffset.y += shift
        swipeStart += shift
        if selection.length > 0 {
            selectedRange = NSRange(location: selection.location + text.length, length: selection.length)
        }
        copied?.location += text.length
        findInteraction?.activeFindSession?.invalidateFoundResults()
    }

    /// Every row is one cell tall, so the content is exactly as tall as its rows.
    private func fitContent() {
        contentSize = CGSize(width: bounds.width, height: CGFloat(rowCount) * style.cell.height)
    }

    private var bottomOffset: CGFloat {
        max(0, CGFloat(rowCount) * style.cell.height - bounds.height)
    }

    private func clamped(_ offset: CGFloat) -> CGFloat {
        min(max(offset, 0), bottomOffset)
    }

    // MARK: Closing

    /// Once scrolling stops at the bottom, the screen under the overlay shows the same rows, live.
    private func settle() {
        if navigation == nil, contentOffset.y >= bottomOffset - 0.5 { close() }
    }

    /// Shows the terminal under the overlay again. The overlay stays on top, letting touches through to
    /// the terminal, until the terminal has drawn its first frame, so nothing blank shows in between.
    private func uncover() {
        covering = false
        terminal.view.isHidden = false
        // Another session's terminal shows now, or Core Graphics draws this one as the overlay leaves.
        guard terminal.view.superview != nil else {
            leave()
            return
        }
        terminal.setVisible(true)
        guard terminal.view.isUsingMetalRenderer else {
            leave()
            return
        }
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(terminalDrew), name: .terminalViewMetalRendererStatusDidChange, object: terminal.view
        )
    }

    /// The terminal under the overlay has drawn, or draws without Metal now (Core Graphics, or another
    /// session took the screen): the overlay can go.
    @objc private func terminalDrew() {
        let view = terminal.view
        if !view.isUsingMetalRenderer || view.metalRendererStatus.presentedFrameCount > 0 { leave() }
    }

    /// Takes the overlay off the screen and lets go of its text.
    private func leave() {
        NotificationCenter.default.removeObserver(self, name: .terminalViewMetalRendererStatusDidChange, object: terminal.view)
        NotificationCenter.default.removeObserver(self, name: UITextField.textDidEndEditingNotification, object: nil)
        removeFromSuperview()
        layout.storage.setAttributedString(NSAttributedString())
    }

    /// New lines move the screen's first line, and the history read no longer ends where the screen
    /// begins. A redraw lower down leaves it where it was.
    private func outputArrived() {
        if TopLine(terminal.view.getTerminal()) != screenTop { close() }
    }

    private func inputSent(_ bytes: ArraySlice<UInt8>) {
        if !Self.isReply(bytes) { close() }
    }

    /// Whether bytes the terminal sends are its own answer rather than typing: a focus report, or a reply
    /// to one of tmux's queries (OSC, DCS, APC, PM, or CSI with a private marker).
    static func isReply(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 3, bytes.first == 0x1B else { return false }
        let kind = bytes[bytes.startIndex + 1]
        let next = bytes[bytes.startIndex + 2]
        switch kind {
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"):
            return true
        case UInt8(ascii: "["):
            if bytes.count == 3, next == UInt8(ascii: "I") || next == UInt8(ascii: "O") { return true }
            return (0x3C...0x3F).contains(next)
        default:
            return false
        }
    }

    // MARK: Momentum

    /// Carries the opening swipe's momentum on after the finger lifts, fading as UIScrollView's does.
    private func startFling(_ speed: CGFloat) {
        stopFling()
        guard abs(speed) > 20 else {
            settle()
            return
        }
        flingSpeed = speed
        flingTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(flingStep))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        fling = link
    }

    @objc private func flingStep(_ link: CADisplayLink) {
        let elapsed = max(link.targetTimestamp - flingTime, 0)
        flingTime = link.targetTimestamp
        let kept = pow(Self.deceleration, elapsed * 1000)
        // How far the speed carries while it fades by `kept`.
        let distance = flingSpeed * CGFloat((kept - 1) / (1000 * Darwin.log(Self.deceleration)))
        flingSpeed *= CGFloat(kept)
        let wanted = contentOffset.y + distance
        let offset = clamped(wanted)
        contentOffset.y = offset
        guard offset == wanted, abs(flingSpeed) > 20 else {
            stopFling()
            settle()
            return
        }
    }

    private func stopFling() {
        fling?.invalidate()
        fling = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopFling()
        super.touchesBegan(touches, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFling() }
    }

    // MARK: Text

    /// Keys typed here go back to the terminal and close the overlay: one the terminal types itself is
    /// typed there, any other only hands the terminal the keyboard back. Command shortcuts, arrows and
    /// paging keys stay here for reading.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, terminal.view.onActionKey?(key) == true {
            return
        }
        if navigationStatus != nil, presses.count == 1, presses.first?.key?.keyCode == .keyboardEscape {
            cancelNavigation()
            return
        }
        guard presses.count == 1, let key = presses.first?.key, !key.modifierFlags.contains(.command),
              !Self.readingKeys.contains(key.keyCode) else {
            super.pressesBegan(presses, with: event)
            return
        }
        let view = terminal.view
        _ = view.becomeFirstResponder()
        if view.typesItself(key) { view.pressesBegan(presses, with: event) }
        close()
    }

    private static let readingKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
        .keyboardPageUp, .keyboardPageDown, .keyboardHome, .keyboardEnd,
        .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
        .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock,
    ]

    /// A copy joins wrapped rows back into their lines and leaves off the blanks after each line, and
    /// flashes what it copied.
    override func copy(_ sender: Any?) {
        guard let text = selectedText, let range = selectedTextRange else { return }
        UIPasteboard.general.string = text
        copied = selectedRange
        CopyFlash.flash(selectionRects(for: range).map(\.rect), in: self, color: terminal.view.nativeForegroundColor)
    }

    /// The selection as a copy takes it, wrapped rows joined back into their lines and the blanks after
    /// each line left off; nil with nothing selected.
    private var selectedText: String? {
        guard selectedRange.length > 0 else { return nil }
        return HistoryText.copied(Substring((layout.storage.string as NSString).substring(with: selectedRange)))
    }

    /// Adds Ask Akyl and a full-history find action when the built-in find interaction is not ready.
    private func withAskAkyl(_ suggested: [UIMenuElement]) -> UIMenu? {
        let offersFind = !isScreen && !isFindInteractionEnabled
        guard (askAkyl != nil && selectedRange.length > 0) || offersFind else { return nil }
        var actions = suggested
        if askAkyl != nil, selectedRange.length > 0 {
            let ask = UIAction(title: "Ask Akyl", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                guard let self, let text = selectedText else { return }
                askAkyl?(text)
            }
            actions.insert(ask, at: 0)
        }
        if offersFind {
            actions.append(UIAction(title: "Find in History", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.find()
            })
        }
        return UIMenu(children: actions)
    }

    /// With Copy on Select on, a selection that is new when the finger lifts goes on the clipboard.
    private func lifted() {
        guard !closed, terminal.view.copyOnSelect else { return }
        guard selectedRange.length > 0 else {
            copied = nil
            return
        }
        if selectedRange != copied { copy(nil) }
    }

    /// Paste is offered as the terminal offers it, and pastes there; like typing, it takes the overlay away.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return terminal.view.canPerformAction(action, withSender: sender) }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let view = terminal.view
        close()
        view.paste(sender)
    }

    /// What VoiceOver and UI tests read: the rows on screen, joined as a copy joins them, rather than
    /// every row held.
    override var accessibilityValue: String? {
        get {
            let glyphs = layout.manager.glyphRange(forBoundingRect: CGRect(origin: contentOffset, size: bounds.size), in: layout.container)
            let characters = layout.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            return HistoryText.copied(Substring((layout.storage.string as NSString).substring(with: characters)))
        }
        set { super.accessibilityValue = newValue }
    }

    // MARK: Selecting on the screen

    /// The word under `point`, or no characters at the one there when it is not in a word.
    private func word(at point: CGPoint) -> NSRange {
        let index = character(at: point)
        guard let position = position(from: beginningOfDocument, offset: index),
              let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward)) else {
            return NSRange(location: index, length: 0)
        }
        return NSRange(location: offset(from: beginningOfDocument, to: word.start), length: offset(from: word.start, to: word.end))
    }

    /// From the word the long press began on to the character under `point`, on either side of it.
    private func selection(to point: CGPoint) -> NSRange {
        let index = character(at: point)
        let start = min(pressedWord.location, index)
        let end = min(max(NSMaxRange(pressedWord), index + 1), layout.storage.length)
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// The character under `point`, or the nearest one on its row.
    private func character(at point: CGPoint) -> Int {
        layout.manager.characterIndex(for: point, in: layout.container, fractionOfDistanceBetweenInsertionPoints: nil)
    }

    /// Shows the menu for what the long press selected: Copy and the rest, or Paste when it selected nothing.
    private func showMenu(at point: CGPoint) {
        let menu = self.menu ?? UIEditMenuInteraction(delegate: self)
        if self.menu == nil {
            addInteraction(menu)
            self.menu = menu
        }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        readOlderIfNear()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopFling()
        highlightedPrompt = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    // MARK: UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Clearing the screen's selection, as a tap does, takes the screen away. While the long press
        // goes on, it sets the selection itself.
        guard isScreen, press == nil else { return }
        if selectedRange.length > 0 {
            hadSelection = true
        } else if hadSelection {
            close()
        }
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        withAskAkyl(suggestedActions)
    }
}

// UIKit leaves this protocol without an actor; its calls come on the main thread, as the menu's do.
extension HistoryView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let range = selectedTextRange, !range.isEmpty else {
            return CGRect(origin: configuration.sourcePoint, size: .zero)
        }
        return selectionRects(for: range).reduce(CGRect.null) { $0.union($1.rect) }
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        withAskAkyl(suggestedActions) ?? UIMenu(children: suggestedActions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        // A long press on nothing put up only the menu; the screen goes with it, unless Select All was chosen.
        animator.addCompletion { [weak self] in
            guard let self, isScreen, selectedRange.length == 0 else { return }
            close()
        }
    }
}

/// The screen's first line with anything on it, and its row. New lines move it; a redraw lower down,
/// such as a spinner or a clock, does not.
private struct TopLine: Equatable {
    let row: Int
    let text: String

    init(_ terminal: Terminal) {
        for row in 0..<terminal.rows {
            let text = terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
            if !text.isEmpty {
                self.row = row
                self.text = text
                return
            }
        }
        row = -1
        text = ""
    }
}
