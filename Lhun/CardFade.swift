import UIKit

/// A killed session's card fades away: its last picture is laid over the card where it stood and fades out
/// in a quarter of a second, while what comes next shows through it. The picture goes once the fade ends.
@MainActor
final class CardFade {
    /// Each open card's frame in the window, kept as it moves.
    var frames: [SessionRef: CGRect] = [:]

    /// Lays the card's picture over the card where it stands, its corners cut as the layout cuts the card's,
    /// and fades it out. Called before the card leaves, so the picture is the card as he last saw it; dialogs
    /// presented over the app are not in it. Returns false when the card is not on screen, and nothing fades.
    @discardableResult
    func start(_ ref: SessionRef, compact: Bool) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let frame = frames[ref], frame.width >= 1, frame.height >= 1,
              let window = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow,
              let root = window.rootViewController?.view, let host = root.superview
        else { return false }
        let card = root.convert(frame, from: window)
        let format = UIGraphicsImageRendererFormat(for: root.traitCollection)
        format.opaque = false
        let picture = UIGraphicsImageRenderer(size: card.size, format: format).image { _ in
            root.drawHierarchy(in: CGRect(origin: CGPoint(x: -card.minX, y: -card.minY), size: root.bounds.size), afterScreenUpdates: false)
        }
        guard let image = picture.cgImage else { return false }

        let shape = UIView(frame: host.convert(card, from: root))
        shape.isUserInteractionEnabled = false
        shape.clipsToBounds = true
        shape.layer.cornerRadius = CardSurface.radius(compact: compact)
        shape.layer.cornerCurve = .continuous
        shape.layer.speed = Float(1 / Effects.pace)
        host.insertSubview(shape, aboveSubview: root)
        let still = CALayer()
        still.frame = shape.bounds
        still.contents = image
        still.contentsScale = picture.scale
        still.opacity = 0
        shape.layer.addSublayer(still)
        Effects.run({
            still.add(CopyFlash.fade(from: 1, duration: 0.25), forKey: "fade")
        }, then: shape.removeFromSuperview)
        return true
    }
}
