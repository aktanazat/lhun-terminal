import CoreText
import GameController
import SwiftTerm
import SwiftUI
import UIKit

/// Shows one session's terminal on its card.
struct TerminalScreen: UIViewRepresentable {
    let terminal: TerminalModel
    /// The colors of its host's theme in the appearance on screen.
    let palette: Theme.Palette
    let fontSize: CGFloat
    let face: TerminalFont
    /// The focused card's terminal takes typing; the other card's only draws.
    let focused: Bool
    /// Beside the focused card: the terminal sits under the card's dim.
    let dimmed: Bool
    /// True while the cards move, the gutter between them is dragged, or the keyboard is away with the
    /// palette, a picker or the inbox: the terminal keeps its grid until they come to rest.
    let holdsGrid: Bool
    /// What is left of the keyboard's move for the card: the grid fits where the card comes to rest.
    let keyboard: KeyboardTravel
    /// False while the peek is out: the on-screen keyboard and its key row step aside.
    let showsKeyboard: Bool
    /// Sends text selected on the screen or in history to the app embedding LhunKit (`Lhun.onAskAkyl`);
    /// nil, no menu offers it.
    let askAkyl: ((String) -> Void)?
    /// ⌃⇥ and ⌃⇧⇥: the open session's next or previous window.
    let onStepWindow: (Int) -> Void
    /// Asked for a font size while a pinch goes on.
    let onZoom: (CGFloat) -> Void

    func makeUIView(context: Context) -> TerminalHost {
        TerminalHost()
    }

    func updateUIView(_ host: TerminalHost, context: Context) {
        host.onZoom = onZoom
        host.holdsGrid = holdsGrid
        host.keyboard = keyboard
        host.showsKeyboard = showsKeyboard
        host.takesTyping = focused
        host.dimmed = dimmed
        host.palette = palette
        host.askAkyl = askAkyl
        host.show(terminal, fontSize: fontSize, face: face)
        terminal.view.onStepWindow = onStepWindow
        terminal.view.findInHistory = { [weak host] in host?.findInHistory() }
        terminal.view.stepPrompt = { [weak host] in host?.stepPrompt($0) }
    }

    static func dismantleUIView(_ host: TerminalHost, coordinator: Void) {
        host.release()
    }
}

/// Holds a card's terminal view. The views belong to their session models and outlive this host: a card
/// that leaves the screen hands its view back, and the next card to show the session moves it in again.
///
/// The terminal always fits its card. The host gives it the most whole columns and rows that fit inside
/// the padding, centered across and set at the top, so no cell is cut off at an edge and tmux is sent
/// exactly the grid on screen. Zooming changes the font size, never the scale, and the grid is fitted
/// again at once.
final class TerminalHost: UIView {
    var onZoom: ((CGFloat) -> Void)?
    /// Whether this card takes typing. Only the focused card's terminal holds the keyboard. (UIView's own
    /// `focused` is about focus movement with a remote or keyboard, which Lhûn does not use.)
    var takesTyping = true {
        didSet {
            guard takesTyping, !oldValue, window != nil else { return }
            takeTypingAfterUpdate()
        }
    }
    /// While the cards move, the gutter between them is dragged, or the keyboard goes to the palette and
    /// comes back, the grid stays as it is, so tmux is sent one size when they come to rest rather than one
    /// per frame or move. The fit waits for the layout pass, which sees the card's final bounds even when
    /// the release and the new frame land in the same update.
    var holdsGrid = false {
        didSet {
            guard oldValue, !holdsGrid else { return }
            setNeedsLayout()
        }
    }
    /// What is left of the keyboard's move for this card. As each move sets off, the grid fits the room the
    /// card has once the keyboard stops, and keeps it until the move ends: tmux is sent one size a move
    /// rather than a row a frame, a keyboard coming up never covers the prompt at the grid's foot, and
    /// the rows one going down uncovers are drawn already.
    var keyboard = KeyboardTravel() {
        didSet {
            guard keyboard != oldValue else { return }
            // A move has set off.
            if keyboard.heading != oldValue.heading || keyboard.screenWidth != oldValue.screenWidth { awaitsKeyboard = nil }
            setNeedsLayout()
        }
    }
    /// False while the peek is out. The on-screen keyboard and its key row step aside for it then, an
    /// input view with no height standing in, and the terminal keeps a hardware keyboard's keys.
    var showsKeyboard = true {
        didSet {
            guard showsKeyboard != oldValue else { return }
            updateInputViews()
        }
    }
    /// The terminal's colors, its key row's and its history's.
    var palette = LhunTheme.mies(dark: false).palette {
        didSet {
            guard palette != oldValue else { return }
            applyTheme()
        }
    }
    /// Beside the focused card the terminal sits under the card's dim, and its text keeps a wider distance
    /// from what it sits on so it still reads there (Contrast.swift).
    var dimmed = false {
        didSet {
            guard dimmed != oldValue, let model else { return }
            Theme.floor(model.view, dimmed: dimmed)
        }
    }
    /// Sends text selected on the screen or in history to the app embedding LhunKit, through the menu over
    /// the selection; nil, the menu does not offer it.
    var askAkyl: ((String) -> Void)? {
        didSet { history?.askAkyl = askAkyl }
    }

    private weak var model: TerminalModel?
    /// The terminal this card showed before the one it shows now, kept under it, unseen, while it still
    /// holds the keyboard. Taken out of the window at once, it let the keyboard go down, and the new one
    /// brought it back up a few frames later, the card stretching to the foot of the window and back in
    /// between. It leaves once the new terminal has the keyboard.
    private var leaving: TerminalModel?
    /// Stands in for the on-screen keyboard while it steps aside.
    private let noKeyboard = UIView()
    private let scrollPan = UIPanGestureRecognizer()
    /// Selects on the screen; SwiftTerm's own long press, which opened a menu without selecting, is off.
    private let press = UILongPressGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    /// The font size when the current pinch began.
    private var pinchStart: CGFloat = 0
    /// The font size and face he chose. A window another screen sizes can show smaller (`watchFontSize`).
    private var chosenFont: CGFloat = 0
    private var chosenFace = TerminalFont.xenon
    /// What lies over the terminal: tmux's history while you read back through it, or the screen while
    /// you select on it.
    private var history: HistoryView?
    /// Whether the terminal has been fitted to this card yet. A card that appears while the cards move
    /// fits its terminal once, so it never shows the size it had on another card.
    private var fitted = false
    /// The keyboard move the grid was fitted for (`KeyboardTravel.heading`), while one goes on.
    private var fittedHeading: CGFloat?
    /// Whether the window stood upright when the grid was last fitted.
    private var fittedUpright: Bool?
    /// A terminal put on the card with the keyboard down, which it is about to bring up, stays unseen and
    /// unfitted until the keyboard's move sets off, so its first grid is the room the card keeps once the
    /// keyboard is up, the one grid tmux ever hears. Fitted at once, it showed the whole card's grid for a
    /// frame and changed it as the keyboard came. The keyboard tells of its move a frame or so after the
    /// terminal has taken it; one that never comes is waited for a quarter second (`awaitKeyboard`). Turned
    /// with the keyboard up, the card takes its new shape at once and the keyboard tells of its new place
    /// some frames later. That report, not the opening deadline, releases the grid: on the iPad it can
    /// arrive after the deadline, which fitted the old keyboard's height before the new one.
    private enum KeyboardWait { case opening, turning }
    private var awaitsKeyboard: KeyboardWait?
    /// ⌘F, held here: sent as the system's Find, it never reached the host on the iPad.
    private let keys = [
        UIKeyCommand(title: "Find in History", action: #selector(TerminalHost.findInHistory), input: "f", modifierFlags: .command),
    ]

    /// The least room around the grid; matches the window padding of the Mac's Ghostty.
    static let padding = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    /// The smallest font a window another screen sizes shrinks to; past it tmux shows the part of the
    /// window around the cursor.
    static let smallestWatchFont: CGFloat = 8

    /// The font size at which a `cols`×`rows` window shows whole in `room`: the chosen size when it fits
    /// at that, else the largest quarter point at which it does, down to `smallest`. A window too big even
    /// then keeps the largest size at which its width fits, down to the same floor, and shows the rows
    /// that fit. Never larger than the chosen size.
    static func watchFontSize(
        cols: Int, rows: Int, room: CGSize, chosen: CGFloat, face: TerminalFont, scale: CGFloat,
        smallest: CGFloat = smallestWatchFont
    ) -> CGFloat {
        func fits(_ size: CGFloat, rowsToo: Bool) -> Bool {
            let cell = cellSize(fontSize: size, face: face, scale: scale)
            return CGFloat(cols) * cell.width <= room.width && (!rowsToo || CGFloat(rows) * cell.height <= room.height)
        }
        if fits(chosen, rowsToo: true) { return chosen }
        let floor = min(chosen, smallest)
        let step: CGFloat = 0.25
        // Cells grow with the font, give or take a pixel: start a step above where they would just fit.
        let unit = cellSize(fontSize: 100, face: face, scale: scale)
        for rowsToo in [true, false] {
            let wide = room.width / (CGFloat(cols) * unit.width)
            let tall = rowsToo ? room.height / (CGFloat(rows) * unit.height) : .infinity
            var size = min(chosen, ((min(wide, tall) * 100 / step).rounded(.down) + 1) * step)
            while size >= floor {
                if fits(size, rowsToo: rowsToo) { return size }
                size -= step
            }
        }
        return floor
    }

    /// A cell at `size` points, measured as SwiftTerm measures it: the width of "W" rounded to the nearest
    /// pixel, the line's height rounded up to whole points and then to pixels.
    static func cellSize(fontSize size: CGFloat, face: TerminalFont, scale: CGFloat) -> CGSize {
        let font = Theme.terminalFonts(size: size, font: face).regular
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: max(1, ceil(height * scale) / scale))
    }

    init() {
        super.init(frame: .zero)
        // While the card shrinks, the terminal keeps its size until the move ends; the card cuts it off.
        clipsToBounds = true
        scrollPan.addTarget(self, action: #selector(scroll(_:)))
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.allowedScrollTypesMask = .all
        addGestureRecognizer(scrollPan)
        press.addTarget(self, action: #selector(longPress(_:)))
        addGestureRecognizer(press)
        pinch.addTarget(self, action: #selector(zoom(_:)))
        addGestureRecognizer(pinch)
        registerForTraitChanges([UITraitDisplayScale.self]) { (host: TerminalHost, _) in
            host.setNeedsLayout()
        }
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalHost is built in code")
    }

    func show(_ next: TerminalModel, fontSize: CGFloat, face: TerminalFont) {
        var changed = fontSize != chosenFont || face != chosenFace
        chosenFont = fontSize
        chosenFace = face
        if next !== model {
            if let model, model.view.superview === self {
                if model.view.isFirstResponder {
                    letGo()
                    leaving = model
                    model.view.alpha = 0
                } else {
                    model.view.removeFromSuperview()
                    model.setVisible(false)
                }
            }
            if leaving === next {
                // Back before it had gone: it still has the keyboard.
                leaving = nil
                next.view.alpha = 1
            }
            model = next
            fitted = false
            awaitsKeyboard = takesTyping && showsKeyboard && keyboard.heading == 0 && GCKeyboard.coalesced == nil
                && !next.view.isFirstResponder ? .opening : nil
            // Another screen taking or leaving the session's size fits the grid again, before tmux hears.
            next.onSizing = { [weak self, weak next] in
                guard let self, let next, next.view.superview === self else { return }
                setNeedsLayout()
                layoutIfNeeded()
            }
            let view = next.view
            // Unfitted, it would show at the size it was made at, or had on another card.
            if awaitsKeyboard != nil { view.isHidden = true }
            // The host places the grid; the scroll view must not add safe-area insets on top of it, which
            // pushed the first column under the card's edge.
            view.contentInsetAdjustmentBehavior = .never
            addSubview(view)
            // Vertical swipes open tmux's history over the terminal, not the view's own (empty) scrollback.
            view.panGestureRecognizer.require(toFail: scrollPan)
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
                recognizer.isEnabled = false
            }
            applyTheme()
            updateInputViews()
            if window != nil { activate() }
            changed = true
        }
        guard changed else { return }
        // History was drawn for the session and font that were showing.
        history?.close()
        // Fits now rather than at the next layout pass, so tmux is sent one size per change. A new font
        // also queues a report of the in-between size; it arrives after this and matches what was sent.
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The card left the screen. Its terminal stops drawing and gives back its Metal view, unless another
    /// card has already taken the view.
    func release() {
        letGo()
        guard let model, model.view.superview === self else { return }
        history?.close()
        model.view.removeFromSuperview()
        model.setVisible(false)
    }

    /// The terminal shown before lets go: out of the card, and drawing no more.
    private func letGo() {
        guard let leaving else { return }
        self.leaving = nil
        guard leaving.view.superview === self else { return }
        leaving.view.removeFromSuperview()
        leaving.view.alpha = 1
        leaving.setVisible(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    /// Sizes the terminal to the most whole columns and rows that fit inside the padding, centered across
    /// on the pixel grid so the text stays sharp, and set at the top: centered down as well, the text moved
    /// half a row each time the keyboard took or gave back a row. While another screen sets the session's
    /// size, the grid is that screen's window instead, at a font small enough to show it whole
    /// (`watchFontSize`), centered in the room left over.
    private func fit() {
        guard let model, awaitsKeyboard == nil, !(holdsGrid && fitted) else { return }
        if let window {
            let upright = window.bounds.height > window.bounds.width
            let turned = fittedUpright.map { $0 != upright } ?? false
            fittedUpright = upright
            // UIKit can retain a hidden keyboard's old heading; a card with no keyboard need not wait.
            if turned, fitted, keyboard.left > 0, keyboard.heading > 0, let screen = window.windowScene?.screen,
               keyboard.screenWidth != screen.coordinateSpace.bounds.width {
                awaitsKeyboard = .turning
                return
            }
        }
        let moving = keyboard.left != 0
        if moving, fitted, fittedHeading == keyboard.heading { return }
        paintAround()
        let padding = Self.padding
        let room = CGSize(
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - keyboard.left - padding.top - padding.bottom
        )
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        var font = chosenFont
        var window: (cols: CGFloat, rows: CGFloat)?
        if case .watch(let cols, let rows) = model.sizing, room.width > 0, room.height > 0 {
            window = (CGFloat(cols), CGFloat(rows))
            font = Self.watchFontSize(cols: cols, rows: rows, room: room, chosen: chosenFont, face: chosenFace, scale: scale)
        }
        if font != model.fontSize || chosenFace != model.face {
            // History was drawn at the font that was showing.
            history?.close()
            model.setFont(size: font, face: chosenFace)
        }
        let cell = model.cellSize
        var cols = (room.width / cell.width).rounded(.down)
        var rows = (room.height / cell.height).rounded(.down)
        if let window {
            cols = min(cols, window.cols)
            rows = min(rows, window.rows)
        }
        guard cols >= 1, rows >= 1 else { return }
        fitted = true
        fittedHeading = moving ? keyboard.heading : nil
        var size = CGSize(width: cols * cell.width, height: rows * cell.height)
        // The terminal counts width / cell width, rounded down; a product a hair under the whole
        // number would cost the last column.
        while (size.width / cell.width).rounded(.down) < cols { size.width = size.width.nextUp }
        while (size.height / cell.height).rounded(.down) < rows { size.height = size.height.nextUp }
        let frame = CGRect(
            x: padding.left + ((room.width - size.width) / 2 * scale).rounded(.down) / scale,
            y: padding.top + (window == nil ? 0 : ((room.height - size.height) / 2 * scale).rounded(.down) / scale),
            width: size.width,
            height: size.height
        )
        if let history {
            // While something lies over the terminal, the terminal keeps its size, so tmux redraws nothing
            // under it. History takes the new room, unless that is too narrow for its rows; the screen
            // stays on the terminal's own cells.
            if frame.width >= model.view.frame.width {
                let wanted = history.isScreen ? model.view.frame : frame
                if history.frame != wanted { history.frame = wanted }
                return
            }
            history.close()
        }
        if model.view.frame != frame { model.view.frame = frame }
        if model.view.isHidden { model.view.isHidden = false }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { activate() }
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // A long press selects whatever runs, the mouse asked for or not, and with the session gone.
        if recognizer === press { return history == nil && model != nil }
        guard recognizer === scrollPan else { return super.gestureRecognizerShouldBegin(recognizer) }
        // A program that asked for the mouse (tmux with `mouse on`, vim) handles swipes itself. Open
        // history scrolls by itself, and only a swipe down goes back in time.
        guard history == nil, let model, model.state == .live, model.view.getTerminal().mouseMode == .off else { return false }
        let velocity = scrollPan.velocity(in: self)
        return velocity.y > abs(velocity.x)
    }

    private func activate() {
        guard let model else { return }
        model.setVisible(true)
        if takesTyping { takeTypingAfterUpdate() }
    }

    /// Gives the keyboard to this card's terminal once SwiftUI's update is over. SwiftUI sets `takesTyping`,
    /// and puts a new card in the window, in the middle of its update. Taken there, the keyboard left the
    /// other card's terminal inside the update too, and SwiftUI, asked mid-update where it had gone, never
    /// came back: Lhûn hung after ⌘[ in a split. A card opened by a session dropped beside another was
    /// refused the keyboard there, and typing went nowhere.
    private func takeTypingAfterUpdate() {
        DispatchQueue.main.async { [weak self] in
            let host = self
            MainActor.assumeIsolated { host?.takeTyping(asksLeft: 30) }
        }
    }

    /// Gives the keyboard to this card's terminal, if the card still takes typing and still shows it, then
    /// lets the terminal shown before go. Just after a session is dropped, UIKit refuses the keyboard for
    /// about a frame (18 to 27 ms on the simulator). Asked again on the next main-queue turn, it was
    /// sometimes still refusing 2 ms later, so the card asks once a frame until UIKit takes it, for half a
    /// second at most.
    private func takeTyping(asksLeft: Int) {
        guard takesTyping, window != nil, let model, model.view.superview === self,
              !model.view.becomeFirstResponder(), asksLeft > 1
        else {
            if awaitsKeyboard == .opening { awaitKeyboard(for: self.model) }
            return letGo()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            let host = self
            MainActor.assumeIsolated { host?.takeTyping(asksLeft: asksLeft - 1) }
        }
    }

    /// Fits a terminal still waiting for the keyboard's move a quarter second after it asked for the
    /// keyboard: it was refused the keyboard, or the keyboard stayed where it was.
    private func awaitKeyboard(for waiting: TerminalModel?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak waiting] in
            let host = self, asked = waiting
            MainActor.assumeIsolated {
                guard let host, host.awaitsKeyboard == .opening, host.model === asked else { return }
                host.awaitsKeyboard = nil
                host.setNeedsLayout()
            }
        }
    }

    private func applyTheme() {
        // History was drawn in the old colors.
        history?.close()
        guard let model else { return }
        Theme.apply(palette, dimmed: dimmed, to: model.view)
        model.view.keyRowPalette = palette
        paintAround()
    }

    /// The card around the grid: the terminal's own color, or a shade off it while another screen sets
    /// the session's size, so the edge of that screen's window shows.
    private func paintAround() {
        guard let model else { return }
        let color = model.sizing == .own ? model.view.nativeBackgroundColor : UIColor(Theme.pill)
        if backgroundColor != color { backgroundColor = color }
    }

    /// The touch key row only makes sense without a hardware keyboard, and neither it nor the on-screen
    /// keyboard shows while the peek is out.
    private func updateInputViews() {
        guard let model else { return }
        let input: UIView? = showsKeyboard ? nil : noKeyboard
        let accessory: UIView? = showsKeyboard && GCKeyboard.coalesced == nil ? model.keyRow : nil
        guard model.view.inputView !== input || model.view.inputAccessoryView !== accessory else { return }
        model.view.inputView = input
        model.view.inputAccessoryView = accessory
        reloadInputViewsAfterUpdate()
    }

    /// Puts the new input views on screen once SwiftUI's update is over. They change in the middle of it,
    /// when the peek opens or the card shows another terminal. Reloaded there, the keyboard moved at once
    /// and laid out the hosting view inside the update, a cycle SwiftUI never came back from: Lhûn hung
    /// for a minute after ⌘⇧\ opened the grid with Reduce Motion on.
    private func reloadInputViewsAfterUpdate() {
        DispatchQueue.main.async { [weak self] in
            let host = self
            MainActor.assumeIsolated { host?.reloadTerminalInputViews() }
        }
    }

    private func reloadTerminalInputViews() {
        guard let model, model.view.superview === self, model.view.isFirstResponder else { return }
        model.view.reloadInputViews()
    }

    @objc private func keyboardsChanged() {
        updateInputViews()
    }

    /// A swipe down lays tmux's history over the terminal, and it moves with the finger from there.
    @objc private func scroll(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began, let model { overlay(on: model).open(following: pan) }
        history?.follow(pan)
    }

    /// A long press lays the screen over the terminal and selects on it as the finger drags.
    @objc private func longPress(_ press: UILongPressGestureRecognizer) {
        if press.state == .began, let model { overlay(on: model).select(from: press) }
        history?.follow(press)
    }

    private func overlay(on model: TerminalModel) -> HistoryView {
        let overlay = HistoryView(terminal: model, palette: palette)
        overlay.askAkyl = askAkyl
        overlay.frame = model.view.frame
        overlay.onClose = { [weak self] in
            self?.history = nil
            // The card may have changed size while the terminal kept its own.
            self?.setNeedsLayout()
        }
        addSubview(overlay)
        history = overlay
        return overlay
    }

    override var keyCommands: [UIKeyCommand]? {
        keys
    }

    /// ⌘F searches tmux's history, laying it over the terminal first when it is not open.
    @objc func findInHistory() {
        if let history, !history.isScreen {
            history.find()
        } else if let model, model.state == .live {
            history?.close()
            overlay(on: model).open(following: nil)
        }
    }

    func stepPrompt(_ step: Int) {
        if let history, !history.isScreen {
            history.stepPrompt(step)
        } else if let model, model.state == .live {
            history?.close()
            overlay(on: model).open(following: nil, promptStep: step)
        }
    }

    /// Pinching zooms as it goes, in whole points; each step fits the grid again.
    @objc private func zoom(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchStart = chosenFont
        case .changed where pinchStart > 0:
            onZoom?(pinchStart * pinch.scale)
        default:
            break
        }
    }
}
