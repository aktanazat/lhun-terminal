import Foundation

/// The motion visible in a trace, independent of the display-link sampler. The key row rides the real
/// keyboard; UIKit's animated stand-in is only the reference when no key row is on screen.
enum MotionTraceSummary {
    private static let still = 0.5

    static func make(
        tracks: [String: [Int: Double]], frameAt: [Int], grids: [String: [String]], dropped: Int,
        keyboardTimings: [[Double]], windowBottom: Double? = nil
    ) -> [String: Any] {
        let reference = tracks["key row"] == nil ? "keyboard" : "key row"
        let visiblePixels = reference == "key row"
        let motions = tracks.reduce(into: [String: Motion]()) { result, track in
            let bottom = track.key.hasSuffix(" bottom") && grids.keys.contains { track.key.dropLast(7) == $0 }
            result[track.key] = motion(
                of: track.value, frameAt: frameAt, visiblePixels: visiblePixels && (track.key == reference || bottom),
                windowBottom: track.key == reference ? windowBottom : nil
            )
        }
        let keyboard = motions[reference]
        var lag: [String: Any] = [:]
        for name in grids.keys {
            guard let bottom = motions["\(name) bottom"], let keyboard,
                  let start = visiblePixels ? bottom.pixelFirst : bottom.first,
                  let end = visiblePixels ? bottom.pixelLast : bottom.last,
                  let keyboardStart = visiblePixels ? keyboard.pixelFirst : keyboard.first,
                  let keyboardEnd = visiblePixels ? (keyboard.departed ?? keyboard.pixelLast) : keyboard.last
            else { continue }
            lag[name] = ["start": start - keyboardStart, "end": end - keyboardEnd]
        }
        // The text's foot and the cursor follow what tmux draws; the regrids count those changes.
        let layoutParts = motions.filter { part, _ in
            part != "keyboard" && part != "key row" && !part.hasSuffix(" text bottom") && !part.hasSuffix(" cursor")
        }
        return [
            "frames": (frameAt.last ?? -1) + 1,
            "dropped": dropped,
            "reversals": layoutParts.values.reduce(0) { $0 + $1.reversals },
            "snaps": layoutParts.values.reduce(0) { $0 + $1.snaps },
            "regrids": grids.values.reduce(0) { $0 + max(0, $1.count - 1) },
            "grids": grids,
            "keyboardReference": reference,
            "keyboardLag": lag,
            "keyboardMoves": keyboardTimings,
            "moved": motions.filter { $0.value.travel > 0 }.mapValues(\.entry),
        ]
    }

    /// Each part's steps of one pixel or more, and the display frames of its first and last steps.
    private struct Motion {
        var travel = 0.0
        var reversals = 0
        var snaps = 0
        var first: Int?
        var last: Int?
        var pixelFirst: Int?
        var pixelLast: Int?
        var departed: Int?

        var entry: [String: Any] {
            var entry: [String: Any] = ["travel": (travel * 10).rounded() / 10, "reversals": reversals, "snaps": snaps]
            if let first { entry["first"] = first }
            if let last { entry["last"] = last }
            return entry
        }
    }

    private static func motion(of positions: [Int: Double], frameAt: [Int], visiblePixels: Bool, windowBottom: Double?) -> Motion {
        let shown = positions.sorted { $0.key < $1.key }
        var motion = Motion()
        let steps = zip(shown, shown.dropFirst()).compactMap { before, after -> (tick: Int, size: Double)? in
            guard after.key == before.key + 1 else { return nil }
            if visiblePixels, (after.value / still).rounded() != (before.value / still).rounded() {
                if motion.pixelFirst == nil { motion.pixelFirst = frameAt[after.key] }
                motion.pixelLast = frameAt[after.key]
            }
            let size = after.value - before.value
            return abs(size) >= still ? (tick: after.key, size: size) : nil
        }
        if visiblePixels, motion.pixelLast != nil,
           let before = shown.dropLast().last, let last = shown.last,
           last.key == before.key + 1, last.value > before.value, last.key + 1 < frameAt.count,
           windowBottom.map({ (last.value / still).rounded() < ($0 / still).rounded() }) ?? true {
            motion.departed = frameAt[last.key + 1]
        }
        motion.travel = steps.reduce(0) { $0 + abs($1.size) }
        motion.first = steps.first.map { frameAt[$0.tick] }
        motion.last = steps.last.map { frameAt[$0.tick] }
        motion.reversals = zip(steps, steps.dropFirst()).filter { ($0.size > 0) != ($1.size > 0) }.count
        if motion.travel >= 10 {
            motion.snaps = steps.filter { abs($0.size) > max(4, motion.travel * 0.3) }.count
        }
        return motion
    }
}
