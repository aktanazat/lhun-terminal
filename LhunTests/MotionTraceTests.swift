import Testing
@testable import LhunKit

/// A terminal must keep time with the keyboard a person sees, not UIKit's sub-pixel stand-in.
struct MotionTraceTests {
    @Test("The real keyboard's last pixel is the timing reference", arguments: [0, 2])
    func realKeyboard(delay: Int) throws {
        let keys: [Double] = [100, 90, 80, 79.5, 79, 78.5, 78]
        let ghost: [Double] = [100, 90, 80, 79.8, 79.6, 79.4, 79.2]
        let bottom = Array(repeating: keys[0] - 8, count: delay) + keys.map { $0 - 8 }
        let summary = MotionTraceSummary.make(
            tracks: [
                "key row": Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.offset, $0.element) }),
                "keyboard": Dictionary(uniqueKeysWithValues: ghost.enumerated().map { ($0.offset, $0.element) }),
                "terminal bottom": Dictionary(uniqueKeysWithValues: bottom.enumerated().map { ($0.offset, $0.element) }),
            ],
            frameAt: Array(0..<bottom.count), grids: ["terminal": ["84x36"]], dropped: 0, keyboardTimings: []
        )
        let lag = try #require((summary["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        #expect(summary["keyboardReference"] as? String == "key row")
        #expect(lag["start"] == delay)
        #expect(lag["end"] == delay)
    }

    @Test("Without a visible key row the announced keyboard remains the reference")
    func withoutKeyRow() throws {
        let positions: [Int: Double] = [0: 100, 1: 90, 2: 80, 3: 70]
        let summary = MotionTraceSummary.make(
            tracks: ["keyboard": positions, "terminal bottom": positions], frameAt: [0, 1, 2, 3],
            grids: ["terminal": ["84x36"]], dropped: 0, keyboardTimings: []
        )
        let lag = try #require((summary["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        #expect(summary["keyboardReference"] as? String == "keyboard")
        #expect(lag["start"] == 0)
        #expect(lag["end"] == 0)
    }
}
