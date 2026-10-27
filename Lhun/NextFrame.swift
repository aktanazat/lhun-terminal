import UIKit

/// Calls back once, at the display's next refresh, with the link that times it. Whatever the screen was
/// given before the call has been committed by then.
@MainActor
final class NextFrame: NSObject {
    private let done: (CADisplayLink) -> Void

    private init(_ done: @escaping (CADisplayLink) -> Void) {
        self.done = done
    }

    static func wait(_ done: @escaping (CADisplayLink) -> Void) {
        // The link keeps its target until the one call invalidates it.
        CADisplayLink(target: NextFrame(done), selector: #selector(NextFrame.tick(_:))).add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        done(link)
    }
}
