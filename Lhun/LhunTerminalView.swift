import SwiftTerm
import UIKit

/// SwiftTerm's terminal view with what Lhûn adds to it: plain keys typed the moment they go down, Caps
/// Lock as Esc when he asks for it, the display held at its full rate while you type, web addresses that
/// open with a tap, and files on the clipboard with no text beside them, copied images included, sent to
/// the host with their paths typed in their place. Text goes to `pasteText`, which types it made safe
/// (Paste). A copy of its own selection (a double tap selects a word, a triple tap a row) flashes what
/// it copied, and with Copy on Select the selection is copied as the finger lifts. While the host's echo
/// is slow, keys typed and not yet echoed show over the cells where they will land (EchoPrediction,
/// PredictionView). A cursor the program asks to blink blinks only for a while after he types.
final class LhunTerminalView: TerminalView {
    /// Told the moment each key press reaches the view, with the time it went down: the event's own time,
    /// on the CACurrentMediaTime clock. Set only while the probe runs.
    var onKeyDown: ((TimeInterval) -> Void)?
    /// Told when a key's text heads for the SSH channel: `true` when Lhûn sent it straight from the key
    /// press, `false` when it came back through the system's text input first. Set only while the probe
    /// runs.
    var onKeyText: ((Bool) -> Void)?
    /// Takes the clipboard's files when it holds files and no text. Unset, such a paste does nothing, as
    /// in SwiftTerm.
    var pasteFiles: (([NSItemProvider]) -> Void)?
    /// Takes the clipboard's text. Unset, a paste types nothing: SwiftTerm's own would type it raw.
    var pasteText: ((String) -> Void)?
    /// Caps Lock sends Esc. The system still turns its lock on and off with the key, so while this is on,
    /// letters come out as Shift says, not as the lock says.
    var capsLockAsEscape = false
    /// Asked first when Esc goes down; true keeps the key from the terminal. Dictation drops its words
    /// this way.
    var onEscape: (() -> Bool)?
    /// Copies a selection as soon as the finger that made it lifts.
    var copyOnSelect = false
    /// Takes ⌃⇥ (1) and ⌃⇧⇥ (-1), which step through tmux's windows instead of reaching the program as a
    /// Tab. Key commands never see them: SwiftTerm takes every Control key as it goes down.
    var onStepWindow: ((Int) -> Void)?
    var onActionKey: ((UIKey) -> Bool)?
    var findInHistory: (() -> Void)?
    var stepPrompt: ((Int) -> Void)?
    /// The colors the key row takes while this terminal has the keyboard; the card sets them with its theme.
    var keyRowPalette: Theme.Palette? {
        didSet { if isFirstResponder { serveKeyRow() } }
    }

    /// The key Lhûn typed that may still be down, and the timer that repeats it while it is.
    private var held: (press: UIPress, repeats: Timer)?
    private var actionPresses = Set<UIPress>()
    /// Holds the display at its full rate, so an echo goes out on the next refresh instead of a slow idle one.
    private var fullSpeed: CADisplayLink?
    private var fullSpeedUntil: CFTimeInterval = 0
    /// SwiftTerm opens a tapped link only once a pointer has hovered over it, which a finger never does.
    /// This tap opens the web address under the finger, behind an OSC 8 link or written out, and lets every
    /// other tap through to SwiftTerm. Like SwiftTerm's own tap it waits out a double tap, which still
    /// selects the word, so a tap takes no longer than before.
    private let linkTap = UITapGestureRecognizer()
    /// The address under the finger, from the moment the link tap begins until it opens.
    private var tappedLink: String?
    /// The selection Copy on Select last copied, so a tap that leaves it as it was copies nothing again.
    private var copied: (start: Position, end: Position)?
    /// Whether a finger is on the terminal, and when the last one lifts.
    private lazy var lift = LiftWatcher { [weak self] in self?.copyOnSelectIfNew() }
    /// The guesses local echo shows, and the ones it showed before the last output, kept up beneath until
    /// a frame with that output is on screen. Neither exists until something is guessed.
    private var guessView: PredictionView?
    private var settlingView: PredictionView?
    /// Lets the old guesses go after 100 ms if no frame comes.
    private var settleDeadline: DispatchWorkItem?
    /// Whether the program on screen shows its cursor. Programs that draw their own, as omp and Claude Code
    /// do, hide it, and keys typed into them are not guessed.
    private(set) var cursorShown = true
    /// A blinking cursor holds still this long after the terminal last sent tmux anything, and at once in
    /// Low Power Mode: each blink is a frame drawn.
    private static let blinkRestsAfter: TimeInterval = 10
    private var blinkRest: DispatchWorkItem?

    override init(frame: CGRect, font: UIFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        linkTap.addTarget(self, action: #selector(openTappedLink))
        for case let tap as UITapGestureRecognizer in gestureRecognizers ?? [] {
            switch tap.numberOfTapsRequired {
            case 1: tap.require(toFail: linkTap)
            case 2: linkTap.require(toFail: tap)
            default: break
            }
        }
        addGestureRecognizer(linkTap)
        addGestureRecognizer(lift)
        NotificationCenter.default.addObserver(
            self, selector: #selector(framePresented), name: .terminalViewMetalRendererStatusDidChange, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil
        )
        cursorBlinks = false
    }

    required init?(coder: NSCoder) {
        fatalError("LhunTerminalView is built in code")
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === linkTap else { return super.gestureRecognizerShouldBegin(recognizer) }
        tappedLink = webLink(at: recognizer.location(in: self))
        return tappedLink != nil
    }

    @objc private func openTappedLink() {
        guard let link = tappedLink else { return }
        tappedLink = nil
        terminalDelegate?.requestOpenLink(source: self, link: link, params: [:])
    }

    /// The web address shown at a point in the view: the target of an OSC 8 link there, or an address
    /// written out in the text. One that hides characters is taken too, so the tap tells him it was blocked.
    private func webLink(at point: CGPoint) -> String? {
        let terminal = getTerminal()
        let grid = getOptimalFrameSize().size
        let col = Int((point.x / grid.width * CGFloat(terminal.cols)).rounded(.down))
        let row = Int(((point.y - contentOffset.y) / grid.height * CGFloat(terminal.rows)).rounded(.down))
        guard (0..<terminal.cols).contains(col), (0..<terminal.rows).contains(row),
              let link = terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit),
              URL(webLink: link) != nil || URL.hidesCharacters(link)
        else { return nil }
        return link
    }

    /// Plain keys skip the system's text input, which takes 35 to 40 ms over each one: Lhûn sends their
    /// bytes here and repeats them while held, as SwiftTerm does for the keys it takes itself.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let onKeyDown, let event { onKeyDown(event.timestamp) }
        stopRepeating()
        holdFullSpeed()
        if presses.count == 1, let press = presses.first, let key = press.key, onActionKey?(key) == true {
            actionPresses.insert(press)
            return
        }
        if presses.count > 1 {
            var forwarded = presses
            for press in presses {
                if let key = press.key, onActionKey?(key) == true {
                    actionPresses.insert(press)
                    forwarded.remove(press)
                }
            }
            if forwarded.count != presses.count {
                if !forwarded.isEmpty { super.pressesBegan(forwarded, with: event) }
                return
            }
        }
        if presses.count == 1, presses.first?.key?.keyCode == .keyboardEscape, onEscape?() == true {
            return
        }
        if capsLockAsEscape, presses.count == 1, let key = presses.first?.key,
           key.keyCode == .keyboardCapsLock || key.keyCode == .keyboardLockingCapsLock {
            type([0x1b])
            return
        }
        if let onStepWindow, let step = Self.windowStep(presses) {
            onStepWindow(step)
            return
        }
        guard presses.count == 1, let press = presses.first, let key = press.key, let bytes = bytes(for: key) else {
            super.pressesBegan(presses, with: event)
            return
        }
        type(bytes)
        let repeats = Timer(fire: .now.addingTimeInterval(0.4), interval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatHeldKey(bytes) }
        }
        RunLoop.main.add(repeats, forMode: .common)
        held = (press, repeats)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !actionPresses.isEmpty else {
            super.pressesEnded(presses, with: event)
            return
        }
        let forwarded = presses.subtracting(actionPresses)
        actionPresses.subtract(presses)
        if !forwarded.isEmpty { super.pressesEnded(forwarded, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating()
        guard !actionPresses.isEmpty else {
            super.pressesCancelled(presses, with: event)
            return
        }
        let forwarded = presses.subtracting(actionPresses)
        actionPresses.subtract(presses)
        if !forwarded.isEmpty { super.pressesCancelled(forwarded, with: event) }
    }

    override func insertText(_ text: String) {
        onKeyText?(false)
        super.insertText(text)
    }

    /// Whether Lhûn types this key itself the moment it goes down, rather than handing it to SwiftTerm and
    /// the system. The history overlay passes such keys on.
    func typesItself(_ key: UIKey) -> Bool {
        bytes(for: key) != nil
    }

    /// 1 for ⌃⇥ and -1 for ⌃⇧⇥, held alone.
    private static func windowStep(_ presses: Set<UIPress>) -> Int? {
        guard presses.count == 1, let key = presses.first?.key, key.keyCode == .keyboardTab else { return nil }
        switch key.modifierFlags.intersection([.control, .shift, .alternate, .command]) {
        case .control: return 1
        case [.control, .shift]: return -1
        default: return nil
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        serveKeyRow()
        wakeCursor()
        return true
    }

    /// The terminal sent tmux something or took the keyboard: a blinking cursor blinks again, for a while.
    func wakeCursor() {
        blinkRest?.cancel()
        blinkRest = nil
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            cursorBlinks = false
            return
        }
        cursorBlinks = true
        let rest = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cursorBlinks = false }
        }
        blinkRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blinkRestsAfter, execute: rest)
    }

    /// iOS posts the change on a thread of its own.
    @objc private nonisolated func powerStateChanged() {
        Task { @MainActor [weak self] in
            guard let self, ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            blinkRest?.cancel()
            blinkRest = nil
            cursorBlinks = false
        }
    }

    override func reloadInputViews() {
        if isFirstResponder { serveKeyRow() }
        super.reloadInputViews()
    }

    override func resignFirstResponder() -> Bool {
        stopRepeating()
        return super.resignFirstResponder()
    }

    /// The key row, the one every terminal shows, sends to this terminal in its colors.
    private func serveKeyRow() {
        (inputAccessoryView as? KeyRow)?.serve(self, palette: keyRowPalette)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        stopRepeating()
        fullSpeed?.invalidate()
        fullSpeed = nil
    }

    /// The bytes of a key Lhûn sends itself: one printable ASCII character, with or without Shift, Return,
    /// Delete, ⌘Delete as Ctrl+U, which erases the line typed so far as Ghostty's does, and with Option as
    /// Meta, Esc and the key Option held, Shift kept. The rest goes to SwiftTerm and the system as before:
    /// other keys with Command or Control, Option keys without Option as Meta, keys after the key row's
    /// sticky Control or Esc, text being composed, input methods that build characters from several keys,
    /// other characters (a dead key's accent among them), and programs that turned on the kitty keyboard
    /// protocol.
    private func bytes(for key: UIKey) -> [UInt8]? {
        if key.keyCode == .keyboardDeleteOrBackspace, markedTextRange == nil,
           key.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command {
            return [0x15]
        }
        guard key.modifierFlags.isDisjoint(with: [.command, .control]), !controlModifier, !metaModifier,
              markedTextRange == nil, getTerminal().keyboardEnhancementFlags.isEmpty, !Self.composes(textInputMode)
        else { return nil }
        if key.modifierFlags.contains(.alternate) {
            guard optionAsMetaKey, let byte = Self.metaByte(for: key) else { return nil }
            return [0x1b, byte]
        }
        switch key.keyCode {
        case .keyboardDeleteOrBackspace:
            return [backspaceSendsControlH ? 0x08 : 0x7F]
        case .keyboardReturnOrEnter, .keypadEnter:
            return returnByteSequence
        default:
            // The keys without a character of their own, the arrows, Esc, Home and End, Page Up and Down
            // and the F-keys, name themselves here ("UIKeyInputLeftArrow"). SwiftTerm sends their
            // sequences, in the cursor mode the program asked for.
            let scalars = key.characters.unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first, (0x20...0x7E).contains(scalar.value) else { return nil }
            let byte = UInt8(scalar.value)
            let isLetter = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            guard capsLockAsEscape, isLetter, key.modifierFlags.contains(.alphaShift) else { return [byte] }
            return [key.modifierFlags.contains(.shift) ? byte & ~0x20 : byte | 0x20]
        }
    }

    /// The character Option held over, as Shift makes it. The system reports Option keys without Shift
    /// (Option-Shift-. comes as "."), so Shift is put back by the US layout.
    private static func metaByte(for key: UIKey) -> UInt8? {
        let scalars = key.charactersIgnoringModifiers.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, (0x20...0x7E).contains(scalar.value) else { return nil }
        let byte = UInt8(scalar.value)
        guard key.modifierFlags.contains(.shift) else { return byte }
        if (0x61...0x7A).contains(byte) { return byte & ~0x20 }
        guard let index = usPlain.firstIndex(of: byte) else { return byte }
        return usShifted[index]
    }

    private static let usPlain = Array("`1234567890-=[]\\;',./".utf8)
    private static let usShifted = Array("~!@#$%^&*()_+{}|:\"<>?".utf8)

    /// Input methods that build one character from several keys.
    private static func composes(_ mode: UITextInputMode?) -> Bool {
        guard let language = mode?.primaryLanguage else { return false }
        return ["ja", "zh", "ko", "yue", "vi"].contains { language.hasPrefix($0) }
    }

    /// Sends the bytes the way SwiftTerm sends a key it takes itself. The system's text input never
    /// hears of them: telling it costs the same 35 ms as letting it type them.
    private func type(_ bytes: [UInt8]) {
        holdFullSpeed()
        onKeyText?(true)
        send(bytes)
    }

    /// SwiftTerm keeps the key-up to itself, so the repeat asks the press whether it is still down.
    private func repeatHeldKey(_ bytes: [UInt8]) {
        guard let press = held?.press, press.phase != .ended, press.phase != .cancelled else {
            stopRepeating()
            return
        }
        type(bytes)
    }

    private func stopRepeating() {
        held?.repeats.invalidate()
        held = nil
    }

    /// Asks for the display's full rate until a second from now.
    private func holdFullSpeed() {
        fullSpeedUntil = CACurrentMediaTime() + 1
        if let fullSpeed {
            fullSpeed.isPaused = false
            return
        }
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(fullSpeedTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        fullSpeed = link
    }

    @objc private func fullSpeedTick(_ link: CADisplayLink) {
        if link.timestamp > fullSpeedUntil { link.isPaused = true }
    }

    override func paste(_ sender: Any?) {
        // Taken during the paste, when the system lets Lhûn read what another app copied without asking.
        let files = pasteFiles == nil ? [] : Upload.files(in: UIPasteboard.general.itemProviders)
        if let pasteFiles, !files.isEmpty {
            pasteFiles(files)
        } else if let text = UIPasteboard.general.string {
            pasteText?(text)
        }
    }

    override func copy(_ sender: Any?) {
        let rects = selectionRects()
        super.copy(sender)
        CopyFlash.flash(rects, in: self, color: nativeForegroundColor)
    }

    /// A double or triple tap selects only once the next tap has failed to come, after the finger lifted.
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if !lift.touching { copyOnSelectIfNew() }
    }

    /// With Copy on Select on, a selection that is new once no finger is down goes on the clipboard and
    /// stays selected, its menu with it.
    private func copyOnSelectIfNew() {
        guard copyOnSelect, selectionActive, selection.hasSelectionRange else {
            copied = nil
            return
        }
        guard copied.map({ $0.start != selection.start || $0.end != selection.end }) ?? true else { return }
        copied = (selection.start, selection.end)
        UIPasteboard.general.string = selection.getSelectedText()
        CopyFlash.flash(selectionRects(), in: self, color: nativeForegroundColor)
    }

    /// The selection's rows on screen in the view's bounds, one rect per row.
    private func selectionRects() -> [CGRect] {
        guard selectionActive else { return [] }
        let terminal = getTerminal()
        let ordered = Position.compare(selection.start, selection.end) == .after
        let (first, last) = ordered ? (selection.end, selection.start) : (selection.start, selection.end)
        let grid = getOptimalFrameSize().size
        let cell = CGSize(width: grid.width / CGFloat(terminal.cols), height: grid.height / CGFloat(terminal.rows))
        let top = terminal.getTopVisibleRow()
        return (first.row...last.row).compactMap { row in
            let screenRow = row - top
            guard (0..<terminal.rows).contains(screenRow) else { return nil }
            let from = row == first.row ? first.col : 0
            let to = row == last.row ? last.col : terminal.cols
            return CGRect(
                x: CGFloat(from) * cell.width, y: contentOffset.y + CGFloat(screenRow) * cell.height,
                width: CGFloat(max(to - from, 0)) * cell.width, height: cell.height
            )
        }
    }

    // MARK: Local echo

    override func showCursor(source: Terminal) {
        super.showCursor(source: source)
        cursorShown = true
    }

    override func hideCursor(source: Terminal) {
        super.hideCursor(source: source)
        cursorShown = false
    }

    /// Guessed characters local echo has on screen, for the probe.
    var predictionCells: Int { (guessView?.guessedCells ?? 0) + (settlingView?.guessedCells ?? 0) }

    /// Draws what local echo shows now (EchoPrediction): typed characters underlined where they will land
    /// and the cursor after them, or nothing. Once output has settled guesses, the ones drawn before stay up
    /// beneath the new drawing until a frame with that output is on screen, so a character its echo matched
    /// is on screen all the way through.
    func showPrediction(_ shown: EchoPrediction.Shown?, afterOutput: Bool) {
        let paint = shown.flatMap(predictionPaint)
        guard paint != guessView?.paint else { return }
        if afterOutput, isUsingMetalRenderer, settlingView?.paint == nil, guessView?.paint != nil {
            (guessView, settlingView) = (settlingView, guessView)
            settleDeadline?.cancel()
            let deadline = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.settled() }
            }
            settleDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: deadline)
        }
        if paint != nil, guessView == nil {
            let view = PredictionView()
            addSubview(view)
            guessView = view
        }
        guard let guessView else { return }
        guessView.show(paint, top: contentOffset.y)
        // Metal's view goes back in under SwiftTerm's caret view whenever the terminal is shown again.
        if paint != nil { bringSubviewToFront(guessView) }
    }

    @objc private func framePresented() {
        guard settlingView?.paint != nil else { return }
        settled()
    }

    private func settled() {
        settleDeadline?.cancel()
        settleDeadline = nil
        settlingView?.show(nil, top: 0)
    }

    /// The guessed cells, the cursor where the guesses put it, and the terminal's own cell over its cursor,
    /// which stays where it was until the echo moves it.
    private func predictionPaint(_ shown: EchoPrediction.Shown) -> PredictionView.Paint? {
        let terminal = getTerminal()
        guard terminal.cols > 0, (0..<terminal.rows).contains(shown.row) else { return nil }
        let guessed = { (byte: UInt8) -> Character? in byte == 0x20 ? nil : Character(UnicodeScalar(byte)) }
        let onScreen = { (col: Int) -> Character? in
            terminal.getCharacter(col: col, row: shown.row).flatMap { $0 == "\0" ? nil : $0 }
        }
        var cells = shown.cells.map { PredictionView.Cell(col: $0.key, character: guessed($0.value), look: .guessed) }
        if shown.cursorCol < terminal.cols {
            let under: Character?
            if let byte = shown.cells[shown.cursorCol] { under = guessed(byte) } else { under = onScreen(shown.cursorCol) }
            cells.removeAll { $0.col == shown.cursorCol }
            cells.append(PredictionView.Cell(col: shown.cursorCol, character: under, look: .cursor))
        }
        let cursor = terminal.getCursorLocation()
        if cursor.y == shown.row, cursor.x < terminal.cols, !cells.contains(where: { $0.col == cursor.x }) {
            cells.append(PredictionView.Cell(col: cursor.x, character: onScreen(cursor.x), look: .plain))
        }
        let grid = getOptimalFrameSize().size
        return PredictionView.Paint(
            row: shown.row,
            cells: cells,
            cellSize: CGSize(width: grid.width / CGFloat(terminal.cols), height: grid.height / CGFloat(terminal.rows)),
            font: font,
            foreground: nativeForegroundColor,
            background: nativeBackgroundColor,
            caret: caretColor,
            caretText: caretTextColor ?? nativeForegroundColor
        )
    }
}

extension URL {
    /// A link a program on the host asks to open, when it is one this device opens: http and https only.
    /// The host decides what it prints, and other schemes would hand it to other apps here.
    init?(webLink link: String) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        self = url
    }

    /// Whether a link's target holds what would make it read as another address: a control character, a
    /// line break, or invisible formatting such as a bidirectional override. Such a link is not opened, as
    /// Ghostty does not open one either.
    static func hidesCharacters(_ link: String) -> Bool {
        ProgramStatus.disarmed(link) != link
    }
}
