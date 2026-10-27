import SwiftTerm
import SwiftUI
import UIKit

/// One attached session, sized by its container, for a chat card.
///
/// It never resizes the session. It shows the window at the size the screens that size it give it, the
/// Mac's terminal for one, scaled down to fit the card (`TerminalModel.watchesOnly`), so a small card never
/// reflows another screen. A session is live in one place at a time: while the terminal space shows it,
/// or another card came on screen with it first, this card shows the session's latest still picture,
/// painted as the peek paints its pictures, and goes live again once the other place lets go. It takes no
/// touches and never the keyboard; a tap is the host app's to route.
public struct SessionTerminal: View {
    private let lhun: Lhun
    private let ref: SessionRef

    public init(_ lhun: Lhun, host: String, session: String) {
        self.lhun = lhun
        ref = SessionRef(host: host, name: session)
    }

    public var body: some View {
        WatchCard(ref: ref)
            .environment(lhun.model)
    }
}

/// A chat card's screen: the session's terminal while the card holds it (`AppModel.watchHolder`), else
/// its latest still picture, which also shows while the terminal is still attaching.
private struct WatchCard: View {
    let ref: SessionRef
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    /// This card, among the cards that want the session live.
    @State private var card = UUID()
    @State private var still: CGImage?
    @State private var size = CGSize.zero

    var body: some View {
        let dark = colorScheme == .dark
        let palette = ThemeStore.shared.palette(for: ref.host, dark: dark)
        let live = model.watchHolder(of: ref) == card
        let terminal = live ? model.watches[ref] : nil
        let link = model.link(for: ref)
        // A still is taken while no attached terminal shows, and again when the session's report changes,
        // the card takes another size, or the appearance turns.
        let attached = terminal.map { $0.state != .connecting } ?? false
        let wanted: StillWanted? = attached ? nil : StillWanted(
            online: link?.status == .online, report: link?.reports.first { $0.name == ref.name }, size: size, dark: dark,
            scale: displayScale
        )
        ZStack {
            Color(uiColor: Theme.uiColor(palette.background))
            if let still {
                Image(decorative: still, scale: displayScale)
                    .resizable()
            }
            if let terminal {
                WatchScreen(terminal: terminal, palette: palette, fontSize: model.fontSize, face: model.terminalFont)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ref.name)’s screen")
        .accessibilityIdentifier("terminal.\(ref.host).\(ref.name)")
        .onAppear { model.wantLive(ref, by: card) }
        .onDisappear { model.letGoLive(ref, by: card) }
        .onChange(of: ref) { left, shown in
            model.letGoLive(left, by: card)
            model.wantLive(shown, by: card)
            model.settleWatch(shown)
        }
        .onChange(of: live, initial: true) { model.settleWatch(ref) }
        .task(id: wanted) {
            guard let wanted, wanted.online,
                  let picture = await model.still(of: ref, size: wanted.size, dark: wanted.dark, scale: wanted.scale),
                  !Task.isCancelled
            else { return }
            still = picture
        }
    }
}

/// What a card's still picture is taken for.
private struct StillWanted: Equatable {
    let online: Bool
    let report: SessionReport?
    let size: CGSize
    let dark: Bool
    let scale: CGFloat
}

extension AppModel {
    /// The session's screen as tmux holds it, painted to fill `size` as the peek paints its pictures. Nil
    /// when its host does not answer or the session is gone.
    fileprivate func still(of ref: SessionRef, size: CGSize, dark: Bool, scale: CGFloat) async -> CGImage? {
        guard size.width > 0, size.height > 0, let link = link(for: ref),
              let output = try? await link.run(Tmux.capture(screenOf: ref.name), timeout: .seconds(5))
        else { return nil }
        let palette = ThemeStore.shared.palette(for: ref.host, dark: dark)
        let font = terminalFont
        return await Task.detached(priority: .userInitiated) {
            Tmux.parseScreens(output).first.flatMap { screen in
                PeekPainter.picture(of: screen, palette: palette, font: font, size: size, scale: scale)
            }
        }.value
    }
}

/// Shows a chat card's terminal.
private struct WatchScreen: UIViewRepresentable {
    let terminal: TerminalModel
    let palette: Theme.Palette
    let fontSize: CGFloat
    let face: TerminalFont

    func makeUIView(context: Context) -> WatchHost {
        WatchHost()
    }

    func updateUIView(_ host: WatchHost, context: Context) {
        host.show(terminal, palette: palette, fontSize: fontSize, face: face)
    }

    static func dismantleUIView(_ host: WatchHost, coordinator: Void) {
        host.release()
    }
}

/// Holds a chat card's terminal view, which belongs to its session's chat-card terminal and moves to the
/// next card that holds the session.
///
/// The grid is always exactly the session's window, so tmux never hears another size, at the largest
/// font that shows the window whole inside the padding, down to `smallestFont`, centered in the card. A
/// window too big even then is cut off at the card's edges, keeping its left edge and its foot, where its
/// lines start and its latest lines are. Nothing shows until the window's size is known. It takes no
/// touches, so a tap on the card is the host app's.
final class WatchHost: UIView {
    /// The smallest font a window shrinks to on a chat card. The card shows the whole window at a glance
    /// rather than reads it, so this is far below the cards' own floor (`TerminalHost.smallestWatchFont`).
    static let smallestFont: CGFloat = 2

    private weak var model: TerminalModel?
    private var palette: Theme.Palette?
    /// The font size and face he chose; the window shows at them when it fits.
    private var chosenFont: CGFloat = 0
    private var chosenFace = TerminalFont.xenon

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitDisplayScale.self]) { (host: WatchHost, _) in
            host.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("WatchHost is built in code")
    }

    func show(_ next: TerminalModel, palette: Theme.Palette, fontSize: CGFloat, face: TerminalFont) {
        var changed = fontSize != chosenFont || face != chosenFace
        chosenFont = fontSize
        chosenFace = face
        if next !== model {
            release()
            model = next
            self.palette = nil
            // The window's size changing fits the grid again, before tmux hears.
            next.onSizing = { [weak self, weak next] in
                guard let self, let next, next.view.superview === self else { return }
                setNeedsLayout()
                layoutIfNeeded()
            }
            let view = next.view
            // Unfitted, it would show at the size it had on another card.
            view.isHidden = true
            view.contentInsetAdjustmentBehavior = .never
            addSubview(view)
            if window != nil { next.setVisible(true) }
            changed = true
        }
        if palette != self.palette {
            self.palette = palette
            Theme.apply(palette, dimmed: false, to: next.view)
            paint()
        }
        guard changed else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The card left the screen. Its terminal stops drawing and gives back its Metal view, unless another
    /// card has already taken the view.
    func release() {
        guard let model, model.view.superview === self else { return }
        model.view.removeFromSuperview()
        model.setVisible(false)
        paint()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let model, model.view.superview === self else { return }
        model.setVisible(true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    /// Sets the font at which the window shows whole and places its grid.
    private func fit() {
        guard let model, model.view.superview === self, case .watch(let cols, let rows) = model.sizing else { return }
        let padding = TerminalHost.padding
        let room = CGSize(width: bounds.width - padding.left - padding.right, height: bounds.height - padding.top - padding.bottom)
        guard room.width > 0, room.height > 0 else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let font = TerminalHost.watchFontSize(
            cols: cols, rows: rows, room: room, chosen: chosenFont, face: chosenFace, scale: scale, smallest: Self.smallestFont
        )
        let view = model.view
        if font != model.fontSize || chosenFace != model.face {
            // The grid in between never has fewer columns or rows than the window: tmux, sent no new size,
            // would never draw again what they cut off. Larger cells take the larger frame first.
            let cell = TerminalHost.cellSize(fontSize: font, face: chosenFace, scale: scale)
            if cell.width > model.cellSize.width || cell.height > model.cellSize.height {
                view.frame = place(cols: cols, rows: rows, cell: cell, room: room, scale: scale)
            }
            model.setFont(size: font, face: chosenFace)
        }
        let frame = place(cols: cols, rows: rows, cell: model.cellSize, room: room, scale: scale)
        if view.frame != frame { view.frame = frame }
        if view.isHidden {
            view.isHidden = false
            paint()
        }
    }

    /// Where a `cols`×`rows` grid of `cell`s sits: centered in the room on the pixel grid, or, too big for
    /// it, from the room's left edge and up from its foot.
    private func place(cols: Int, rows: Int, cell: CGSize, room: CGSize, scale: CGFloat) -> CGRect {
        var size = CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        // The terminal counts width / cell width, rounded down; a product a hair under the whole number
        // would cost the last column.
        while (size.width / cell.width).rounded(.down) < CGFloat(cols) { size.width = size.width.nextUp }
        while (size.height / cell.height).rounded(.down) < CGFloat(rows) { size.height = size.height.nextUp }
        let x = size.width > room.width ? 0 : ((room.width - size.width) / 2 * scale).rounded(.down) / scale
        let y = size.height > room.height
            ? ((room.height - size.height) * scale).rounded(.down) / scale
            : ((room.height - size.height) / 2 * scale).rounded(.down) / scale
        let padding = TerminalHost.padding
        return CGRect(x: padding.left + x, y: padding.top + y, width: size.width, height: size.height)
    }

    /// The card around the grid takes the terminal's color once the terminal shows; until then the still
    /// picture under it shows through.
    private func paint() {
        let shown = model.map { !$0.view.isHidden && $0.view.superview === self } ?? false
        let color = shown ? model?.view.nativeBackgroundColor : nil
        if backgroundColor != color { backgroundColor = color }
    }
}
