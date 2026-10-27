import XCTest

extension XCTestCase {
    /// Reveals a session's pill in a crowded strip and returns it. It checks where the pill lies against
    /// the strip's scroll view before asking XCTest for a hit point: asking about a pill even partly
    /// scrolled out of the window fails the test instead of answering no. A drag that starts with a press of
    /// half a second would lift a pill, so each drag starts at once; and one that barely moves reads as a long
    /// press, which opens the pill's menu.
    @MainActor
    func onStrip(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let id = "session.mac.\(name)"
        let pill = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "\(name) never appeared")
        let strip = app.scrollViews.containing(.button, identifier: id).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "\(name) has no session strip")
        let viewport = strip.frame
        // The whole pill when it fits in the strip with room to spare, else its middle, well clear of the
        // strip's ends. On an iPhone one pill takes nearly the whole strip, where asking for all of it would
        // only be met by drags of a few points, each a long press.
        func shown(_ frame: CGRect) -> Bool {
            guard frame.width <= viewport.width - 40 else {
                return viewport.insetBy(dx: 20, dy: 0).contains(CGPoint(x: frame.midX, y: viewport.midY))
            }
            return frame.minX >= viewport.minX && frame.maxX <= viewport.maxX
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Each drag carries the pill's middle toward the strip's, as far as one drag inside the strip reaches,
        // and holds still before letting go. The strip glides on by about half a second of the drag's speed
        // all the same. A fast drag is only for a pill further off than a drag and that glide together; nearer,
        // a slow one glides a quarter of the strip at most, so it stops inside the strip's middle. On an
        // iPhone's narrow strip a fast drag would carry the strip past the pill, and the next one past it the
        // other way.
        let reach = viewport.width - 40
        let (fast, slow): (CGFloat, CGFloat) = (600, min(150, reach / 2))
        var frame = restingFrame(of: pill)
        for _ in 0..<12 where !shown(frame) {
            let gap = viewport.midX - frame.midX
            let distance = max(-reach, min(reach, gap))
            let from = distance < 0 ? viewport.maxX - 20 : viewport.minX + 20
            origin.withOffset(CGVector(dx: from, dy: viewport.midY)).press(
                forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: from + distance, dy: viewport.midY)),
                withVelocity: XCUIGestureVelocity(rawValue: abs(gap) > reach + fast / 2 ? fast : slow),
                thenHoldForDuration: 0.3
            )
            frame = restingFrame(of: pill)
        }
        XCTAssertTrue(shown(frame) && pill.isHittable, "\(name)'s pill never came on screen")
        return pill
    }

    /// The pill's frame once a flick's glide has stopped: the same in two looks a quarter second apart.
    @MainActor
    private func restingFrame(of pill: XCUIElement) -> CGRect {
        var frame = pill.frame
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = pill.frame
            if now == frame { break }
            frame = now
        }
        return frame
    }
}
