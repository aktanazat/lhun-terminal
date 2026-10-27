import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The effects Lhûn draws for a moment and then takes away: a copy's flash and a killed card's fade.
@MainActor
enum Effects {
    /// Flashes and card fades on screen. The probe reports it: once they end, nothing of theirs is left.
    private(set) static var running = 0
    /// How many times slower effects run, so a device check can photograph one halfway: the
    /// `-effectsPace` launch argument, read only with the probe on. Otherwise 1.
    static let pace = Probe.isOn ? max(1, LhunDefaults.shared.double(forKey: "effectsPace")) : 1

    /// Counts an effect in and runs `animations` in one transaction; once they have all ended, `finish`
    /// takes the effect's layers away and it is counted out.
    static func run(_ animations: () -> Void, then finish: @escaping @MainActor () -> Void) {
        running += 1
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                finish()
                running -= 1
            }
        }
        animations()
        CATransaction.commit()
    }
}

/// A copy flashes what it copied, so he knows it worked: a light sweeps across it and the brightening
/// fades, 0.4 s in all. With Reduce Motion on it only fades, in 0.25 s.
@MainActor
enum CopyFlash {
    /// How strongly a flash tints: a selection's few rows, or a whole card.
    enum Strength {
        case selection, card

        fileprivate var alpha: CGFloat {
            switch self {
            case .selection: 0.3
            case .card: 0.12
            }
        }
    }

    /// Flashes `rects`, given in `view`'s bounds, in `color`, the terminal's foreground in its theme: lighter
    /// on a dark terminal, darker on a light one.
    static func flash(_ rects: [CGRect], in view: UIView, color: UIColor, strength: Strength = .selection) {
        let rects = rects.filter { $0.width > 0 && $0.height > 0 }
        guard !rects.isEmpty else { return }
        let still = UIAccessibility.isReduceMotionEnabled
        let layers = rects.map { rect in
            let glow = CALayer()
            glow.frame = rect
            glow.backgroundColor = color.withAlphaComponent(strength.alpha).cgColor
            glow.cornerRadius = strength == .card ? 0 : 3
            glow.opacity = 0
            glow.speed = Float(1 / Effects.pace)
            return glow
        }
        Effects.run({
            for glow in layers {
                view.layer.addSublayer(glow)
                if still {
                    glow.add(fade(from: 1, duration: 0.25), forKey: "flash")
                    continue
                }
                // Up at once, held a moment, then faded.
                let brighten = CAKeyframeAnimation(keyPath: "opacity")
                brighten.values = [0, 1, 1, 0]
                brighten.keyTimes = [0, 0.15, 0.35, 1]
                brighten.duration = 0.4
                brighten.timingFunctions = [.init(name: .easeOut), .init(name: .linear), .init(name: .easeIn)]
                glow.add(brighten, forKey: "flash")
                glow.addSublayer(sweep(across: glow.bounds, color: color))
            }
        }, then: {
            for glow in layers { glow.removeFromSuperlayer() }
        })
    }

    /// A band of light that crosses the rect left to right in the first 0.25 s.
    private static func sweep(across bounds: CGRect, color: UIColor) -> CAGradientLayer {
        let band = CAGradientLayer()
        band.frame = bounds
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [color.withAlphaComponent(0), color.withAlphaComponent(0.5), color.withAlphaComponent(0)].map(\.cgColor)
        band.locations = [1.2, 1.3, 1.4]
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-0.4, -0.2, 0]
        move.toValue = [1, 1.2, 1.4]
        move.duration = 0.25
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(move, forKey: "sweep")
        return band
    }

    static func fade(from opacity: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        fade.duration = duration
        return fade
    }
}

/// Tells its view each time the last finger lifts, after whatever else the touches did, such as setting
/// a selection, and knows whether a finger is down. It never recognizes, never holds a touch back, and
/// never stops another recognizer.
final class LiftWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private(set) var touching = false
    private let lifted: @MainActor () -> Void

    init(_ lifted: @escaping @MainActor () -> Void) {
        self.lifted = lifted
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touching = true
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, event)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent) {
        let down = (event.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        guard down.subtracting(touches).isEmpty else { return }
        state = .failed
        touching = false
        // After the other recognizers' actions for these touches have run.
        Task { @MainActor [lifted] in lifted() }
    }

    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ prevented: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
