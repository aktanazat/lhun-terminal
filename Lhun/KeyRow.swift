import SwiftTerm
import UIKit

/// The row above the on-screen keyboard with the keys a terminal needs and iOS leaves out.
/// It is hidden while a hardware keyboard is connected. Every terminal shows the same row, which sends to
/// whichever one has the keyboard (`serve`): two rows, one per terminal, made UIKit take one down and put
/// the other up whenever the keyboard went from one terminal to another, and the cards dipped with it.
final class KeyRow: UIInputView, UIInputViewAudioFeedback {
    private enum Key {
        case send(String, [UInt8])
        case control
        case arrow(String, normal: [UInt8], app: [UInt8])
        case path
        case dictate
        case dismiss
    }

    private static let keys: [Key] = [
        .send("esc", [0x1B]),
        .control,
        .send("tab", [0x09]),
        .arrow("arrow.left", normal: EscapeSequences.moveLeftNormal, app: EscapeSequences.moveLeftApp),
        .arrow("arrow.down", normal: EscapeSequences.moveDownNormal, app: EscapeSequences.moveDownApp),
        .arrow("arrow.up", normal: EscapeSequences.moveUpNormal, app: EscapeSequences.moveUpApp),
        .arrow("arrow.right", normal: EscapeSequences.moveRightNormal, app: EscapeSequences.moveRightApp),
        .send("~", Array("~".utf8)),
        .send("|", Array("|".utf8)),
        .send("/", Array("/".utf8)),
        .send("-", Array("-".utf8)),
        .path,
        .dictate,
        .dismiss,
    ]

    static let height: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 54 : 46
    /// Where each key's face sits in the slot that takes its touches: the faces keep 6 points between them
    /// and above and below, and a touch anywhere in the row lands on a key.
    private static let faceInsets = NSDirectionalEdgeInsets(top: 6, leading: 3, bottom: 6, trailing: 3)
    /// The largest text size the keys take. A phone's keys are as narrow as 26 points, which holds "esc" at
    /// the default size and no larger; an iPad's hold it up to the largest size the strip and card headers take.
    private static let largestText: UIContentSizeCategory = UIDevice.current.userInterfaceIdiom == .pad ? .extraExtraExtraLarge : .large

    private weak var terminal: TerminalView?
    /// The colors the keys took last, from the terminal they serve.
    private var palette: Theme.Palette?
    private var buttons: [UIButton] = []
    private var controlKey: UIButton?
    private var dictateKey: UIButton?
    private var repeatTimer: Timer?
    /// The keys in the terminal's colors, set by `apply(_:)`.
    private var face = UIColor(white: 0, alpha: 0.05)
    private var ink = UIColor.secondaryLabel
    private var armedFace = UIColor.label
    private var armedInk = UIColor.systemBackground
    /// Opens the path picker; the app sets it.
    var onPath: (() -> Void)?
    /// Starts dictation, or types what it heard; the app sets it.
    var onDictate: (() -> Void)?
    /// Asked first when Esc is tapped; true keeps it from the terminal. The app sets it.
    var onEscape: (() -> Bool)?

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        maximumContentSizeCategory = Self.largestText
        buttons = Self.keys.map(makeButton)
        layout(buttons)
    }

    /// Sends to `terminal` from now on, in its colors: the terminal that has just taken the keyboard.
    func serve(_ terminal: TerminalView, palette: Theme.Palette?) {
        if terminal !== self.terminal {
            let center = NotificationCenter.default
            center.removeObserver(self, name: .terminalViewControlModifierReset, object: nil)
            self.terminal = terminal
            center.addObserver(self, selector: #selector(controlChanged), name: .terminalViewControlModifierReset, object: terminal)
        }
        if let palette, palette != self.palette {
            apply(palette)
        } else {
            controlChanged()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("KeyRow is built in code")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    private func layout(_ buttons: [UIButton]) {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let guide = safeAreaLayoutGuide
        let fullWidth = row.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -2 * Self.faceInsets.leading)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Keys stay key-sized on a wide iPad screen instead of stretching into slabs.
            row.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(buttons.count) * 72),
            fullWidth,
        ])
    }

    /// The keys take the theme's foreground: a faint face, and labels a little softer than its text.
    /// Armed, ctrl turns solid in it.
    private func apply(_ palette: Theme.Palette) {
        self.palette = palette
        let foreground = Theme.uiColor(palette.foreground)
        face = foreground.withAlphaComponent(palette.isLight ? 0.06 : 0.1)
        ink = foreground.withAlphaComponent(0.7)
        armedFace = foreground
        armedInk = Theme.uiColor(palette.background)
        for button in buttons {
            button.configuration?.baseBackgroundColor = face
            button.configuration?.baseForegroundColor = ink
        }
        controlChanged()
    }

    private func makeButton(_ key: Key) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = face
        config.baseForegroundColor = ink
        config.cornerStyle = .small
        config.background.backgroundInsets = Self.faceInsets
        config.contentInsets = .zero
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        let button = UIButton(configuration: config)
        switch key {
        case .send(let label, let bytes):
            setTitle(label, on: button)
            button.accessibilityLabel = label == "esc" ? "Escape" : label == "tab" ? "Tab" : label
            button.addAction(UIAction { [weak self] _ in self?.send(bytes) }, for: .touchUpInside)
        case .control:
            setTitle("ctrl", on: button)
            button.accessibilityLabel = "Control"
            button.addAction(UIAction { [weak self] _ in self?.toggleControl() }, for: .touchUpInside)
            controlKey = button
        case .arrow(let symbol, let normal, let app):
            button.configuration?.image = UIImage(systemName: symbol)
            button.accessibilityLabel = symbol.replacing("arrow.", with: "").capitalized
            button.addAction(UIAction { [weak self] _ in self?.startRepeating(normal: normal, app: app) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        case .path:
            button.configuration?.image = UIImage(systemName: "folder")
            button.accessibilityLabel = "Insert Path"
            button.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.onPath?()
            }, for: .touchUpInside)
        case .dictate:
            button.configuration?.image = UIImage(systemName: "mic")
            button.accessibilityLabel = "Dictate"
            button.accessibilityIdentifier = "key.dictate"
            button.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.onDictate?()
            }, for: .touchUpInside)
            dictateKey = button
        case .dismiss:
            button.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
            button.accessibilityLabel = "Hide Keyboard"
            button.addAction(UIAction { [weak self] _ in _ = self?.terminal?.resignFirstResponder() }, for: .touchUpInside)
        }
        return button
    }

    /// Shows `text` on the key in the system font at the reader's text size: the subheadline for a word, and
    /// the body for a lone symbol, since a lone ~ or - is a speck at the size the words take. The handler
    /// reads the button's traits, so UIKit runs it again when the text size changes.
    private func setTitle(_ text: String, on button: UIButton) {
        let style: UIFont.TextStyle = text.count == 1 ? .body : .subheadline
        button.configurationUpdateHandler = { button in
            var title = AttributedString(text)
            title.font = UIFont.preferredFont(forTextStyle: style, compatibleWith: button.traitCollection)
            button.configuration?.attributedTitle = title
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard let terminal else { return }
        if bytes == [0x1B], onEscape?() == true {
            UIDevice.current.playInputClick()
            return
        }
        terminal.send(bytes)
        terminal.controlModifier = false
        UIDevice.current.playInputClick()
    }

    private func toggleControl() {
        guard let terminal else { return }
        terminal.controlModifier.toggle()
        controlChanged()
        UIDevice.current.playInputClick()
    }

    /// Ctrl stays armed for the next key, then the terminal releases it.
    @objc private func controlChanged() {
        let armed = terminal?.controlModifier == true
        controlKey?.configuration?.baseBackgroundColor = armed ? armedFace : face
        controlKey?.configuration?.baseForegroundColor = armed ? armedInk : ink
    }

    /// The mic key stays lit while dictation listens: filled, in the full foreground an armed ctrl takes.
    func showDictating(_ listening: Bool) {
        dictateKey?.configuration?.image = UIImage(systemName: listening ? "mic.fill" : "mic")
        dictateKey?.configuration?.baseForegroundColor = listening ? armedFace : ink
        dictateKey?.accessibilityValue = listening ? "listening" : nil
    }

    /// Arrows repeat while held, like the hardware keys.
    private func startRepeating(normal: [UInt8], app: [UInt8]) {
        sendArrow(normal: normal, app: app)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sendArrow(normal: normal, app: app) }
                }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func sendArrow(normal: [UInt8], app: [UInt8]) {
        guard let terminal else { return }
        terminal.send(terminal.getTerminal().applicationCursor ? app : normal)
        UIDevice.current.playInputClick()
    }
}
