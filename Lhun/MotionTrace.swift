import SwiftTerm
import UIKit

/// Follows, one display frame at a time, how the terminals on screen move while a UI test does one thing,
/// as the eye sees them: each terminal's area on its card (`left`, `top`, `bottom`), its text (`text top`,
/// `text bottom`) and its cursor (`cursor`), where the eye rests, in the window's points as Core Animation
/// shows them at that frame, read from the presentation layers. Beside them goes the top of the on-screen
/// keyboard: `key row`, the key row riding on the real keyboard, where one shows, and `keyboard`, a
/// stand-in view put through UIKit's announced moves. The visible key row is the timing reference;
/// the stand-in is used only where no key row shows.
///
/// What jars shows in the summary: a reversal is an edge going one way and then back, a terminal pushed up
/// and let down again; a snap is an edge covering most of its travel in one frame, a jump rather than a
/// move. Both are counted on what the layout moves: the terminal's area on its card and its text's top.
/// The text's foot and the cursor move with what tmux draws, a grid gaining or losing rows or the cursor
/// going down a line; those changes are the regrids, the grids a terminal took after its first, each one
/// redrawn by tmux. Dropped counts the display frames the main thread missed. A terminal's bottom should
/// set off on the frame the keyboard does and come to rest with it: `keyboardLag` gives the frames between
/// their starts and their stops, and `keyboardMoves` the duration and curve UIKit gave each move.
@MainActor
final class MotionTrace: NSObject {

    private let terminals: () -> [TerminalModel]
    private var link: CADisplayLink?
    /// The display frame of each callback, counting the frames the main thread missed between them.
    private var frameAt: [Int] = []
    private var dropped = 0
    private var lastTimestamp: CFTimeInterval?
    /// Where each part was at each callback it showed in, by callback.
    private var tracks: [String: [Int: Double]] = [:]
    /// Each terminal's grids in the order it showed them, as columns x rows.
    private var grids: [String: [String]] = [:]
    /// Moves as the keyboard moves, from UIKit's account of each move.
    private var ghost: UIView?
    private var keyboardMoves: NSObjectProtocol?
    /// Each keyboard move the trace saw: the frame it was told on, UIKit's duration and curve, and where the
    /// keyboard's top sets off from and goes to in the window.
    private var keyboardTimings: [[Double]] = []

    init(terminals: @escaping () -> [TerminalModel]) {
        self.terminals = terminals
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        // With no queue the block runs as the notification posts, inside the update that sets the keyboard
        // moving, so the stand-in starts on the same frame.
        keyboardMoves = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            guard let begin = info[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect,
                  let end = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
            let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated { self?.keyboardMoving(from: begin, to: end, duration: duration, curve: curve) }
        }
    }

    /// Ends the trace: its summary, and every position it took for the log.
    func stop() -> (summary: [String: Any], frames: [String: Any]) {
        link?.invalidate()
        link = nil
        if let keyboardMoves { NotificationCenter.default.removeObserver(keyboardMoves) }
        keyboardMoves = nil
        ghost?.removeFromSuperview()
        ghost = nil
        return (summary(), log())
    }

    private func keyboardMoving(from begin: CGRect, to end: CGRect, duration: Double, curve: UInt) {
        guard let window = terminals().lazy.compactMap(\.view.window).first,
              let screen = window.windowScene?.screen
        else { return }
        let from = window.convert(begin, from: screen.coordinateSpace).minY
        let to = window.convert(end, from: screen.coordinateSpace).minY
        let ghost = self.ghost ?? {
            let view = UIView(frame: CGRect(x: 0, y: from, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.alpha = 0
            window.addSubview(view)
            self.ghost = view
            return view
        }()
        keyboardTimings.append([
            Double((frameAt.last ?? -1) + 1), (duration * 1000).rounded() / 1000, Double(curve), from.rounded(), to.rounded(),
        ])
        // A move that overtakes one under way sets off from where the keyboard is, as the keyboard's does.
        if ghost.layer.animationKeys()?.isEmpty ?? true {
            UIView.performWithoutAnimation { ghost.frame.origin.y = from }
        }
        UIView.animate(
            withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]
        ) {
            ghost.frame.origin.y = to
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        var frame = (frameAt.last ?? -1) + 1
        let interval = link.targetTimestamp - link.timestamp
        if let lastTimestamp, interval > 0 {
            let missed = max(0, Int(((link.timestamp - lastTimestamp) / interval).rounded()) - 1)
            dropped += missed
            frame += missed
        }
        lastTimestamp = link.timestamp
        let tick = frameAt.count
        frameAt.append(frame)
        let shown = terminals()
        for terminal in shown {
            let view = terminal.view
            // A terminal unseen, waiting to fit or handing the keyboard over, is no part of the picture.
            guard let window = view.window, let area = view.superview, !view.isHidden, view.alpha > 0 else { continue }
            let space = window.layer.presentation() ?? window.layer
            let card = Self.onScreen(area.layer, in: space)
            let text = Self.onScreen(view.layer, in: space)
            let name = terminal.name
            put(card.minX, "\(name) left", tick)
            put(card.minY, "\(name) top", tick)
            put(card.maxY, "\(name) bottom", tick)
            put(text.minY, "\(name) text top", tick)
            put(text.maxY, "\(name) text bottom", tick)
            let size = view.getTerminal()
            put(text.minY + CGFloat(size.getCursorLocation().y) * terminal.cellSize.height, "\(name) cursor", tick)
            let grid = "\(size.cols)x\(size.rows)"
            if grids[name]?.last != grid { grids[name, default: []].append(grid) }
        }
        if let keys = shown.first?.keyRow, let keysWindow = keys.window,
           let window = shown.lazy.compactMap(\.view.window).first {
            let keysSpace = keysWindow.layer.presentation() ?? keysWindow.layer
            put(window.convert(Self.onScreen(keys.layer, in: keysSpace), from: keysWindow).minY, "key row", tick)
        }
        if let ghost, let layer = ghost.layer.presentation() {
            put(layer.frame.minY, "keyboard", tick)
        }
    }

    private func put(_ value: CGFloat, _ part: String, _ tick: Int) {
        tracks[part, default: [:]][tick] = Double(value)
    }

    /// A layer's bounds where Core Animation shows them this frame, in the space of `space`, a presentation layer.
    private static func onScreen(_ layer: CALayer, in space: CALayer) -> CGRect {
        guard let shown = layer.presentation() else { return layer.convert(layer.bounds, to: space.model()) }
        return shown.convert(shown.bounds, to: space)
    }

    private func summary() -> [String: Any] {
        MotionTraceSummary.make(
            tracks: tracks, frameAt: frameAt, grids: grids, dropped: dropped, keyboardTimings: keyboardTimings,
            windowBottom: terminals().lazy.compactMap(\.view.window).first.map { Double($0.bounds.maxY) }
        )
    }

    /// Every position, by part, one entry per callback (null where the part was not on screen), with the
    /// display frame of each callback.
    private func log() -> [String: Any] {
        var parts: [String: Any] = [:]
        for (part, positions) in tracks {
            parts[part] = frameAt.indices.map { tick -> Any in
                positions[tick].map { ($0 * 100).rounded() / 100 } ?? NSNull()
            }
        }
        return ["frameAt": frameAt, "parts": parts]
    }
}
