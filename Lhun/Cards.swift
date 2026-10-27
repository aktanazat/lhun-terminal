import CoreGraphics

/// A half of the area the cards share: where a dropped pill or a split opens its session.
enum Half: Equatable, Sendable {
    case left, right, top, bottom

    /// The half whose edge lies nearest the point, each distance taken as a share of the area's width or
    /// height, so the area's diagonals part the four halves. A tie goes to left or right.
    init(nearest point: CGPoint, in size: CGSize) {
        let x = size.width > 0 ? point.x / size.width : 0.5
        let y = size.height > 0 ? point.y / size.height : 0.5
        let across: (half: Half, distance: CGFloat) = x < 0.5 ? (.left, x) : (.right, 1 - x)
        let down: (half: Half, distance: CGFloat) = y < 0.5 ? (.top, y) : (.bottom, 1 - y)
        self = down.distance < across.distance ? down.half : across.half
    }

    /// Top and bottom stack the cards; left and right put them side by side.
    var stacks: Bool {
        self == .top || self == .bottom
    }

    /// Left and top come first in reading order.
    var isFirst: Bool {
        self == .left || self == .top
    }
}

/// A card on screen and the session it shows. The card outlives the session in it (`AppModel.cards`).
struct ShownCard: Hashable {
    let id: Int
    let ref: SessionRef
}

/// Where the cards sit in the area: one fills it; two share it, side by side or stacked, with a gutter
/// between them and the first taking `share` of the room the gutter leaves.
struct CardLayout: Equatable {
    var stacked: Bool
    var share: CGFloat

    /// The wash between the two cards. The compact layout has none; a hairline parts them there.
    var gutter: CGFloat = Metrics.gutter

    /// The cards' frames, in reading order, in whole points.
    func frames(count: Int, in size: CGSize) -> [CGRect] {
        let whole = CGRect(origin: .zero, size: size)
        guard count == 2 else { return Array(repeating: whole, count: count) }
        let room = max((stacked ? size.height : size.width) - gutter, 0)
        let first = (room * share).rounded()
        let second = room - first
        if stacked {
            return [
                CGRect(x: 0, y: 0, width: size.width, height: first),
                CGRect(x: 0, y: first + gutter, width: size.width, height: second),
            ]
        }
        return [
            CGRect(x: 0, y: 0, width: first, height: size.height),
            CGRect(x: first + gutter, y: 0, width: second, height: size.height),
        ]
    }

    /// The frame a card opening on `half` takes, before any share is set.
    func zone(_ half: Half, in size: CGSize) -> CGRect {
        CardLayout(stacked: half.stacks, share: 0.5, gutter: gutter).frames(count: 2, in: size)[half.isFirst ? 0 : 1]
    }
}
struct CardSplitFrame: Identifiable {
    let path: [Int]
    let stacked: Bool
    let share: CGFloat
    let area: CGRect
    let first: CGRect
    let second: CGRect

    var id: String { path.map(String.init).joined(separator: ".") }

}

struct CardGeometry {
    var frames: [(ref: SessionRef, frame: CGRect)] = []
    var splits: [CardSplitFrame] = []

    func frame(for ref: SessionRef) -> CGRect? { frames.first { $0.ref == ref }?.frame }

    func ref(at point: CGPoint) -> SessionRef? {
        frames.first { $0.frame.contains(point) }?.ref
            ?? frames.min { $0.frame.midpoint.distance(to: point) < $1.frame.midpoint.distance(to: point) }?.ref
    }
}

private extension CGRect {
    var midpoint: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let x = self.x - other.x
        let y = self.y - other.y
        return x * x + y * y
    }
}

extension CardTree {
    func geometry(in size: CGSize, gutter: CGFloat, dragging: (path: [Int], share: CGFloat)? = nil) -> CardGeometry {
        var result = CardGeometry()
        collect(in: CGRect(origin: .zero, size: size), gutter: gutter, path: [], dragging: dragging, into: &result)
        return result
    }

    private func collect(in area: CGRect, gutter: CGFloat, path: [Int],
                         dragging: (path: [Int], share: CGFloat)?, into result: inout CardGeometry) {
        switch self {
        case .leaf(let ref):
            result.frames.append((ref, area))
        case .split(let stacked, let stored, let first, let second):
            let share = dragging.flatMap { $0.path == path ? $0.share : nil } ?? CGFloat(stored)
            let room = max((stacked ? area.height : area.width) - gutter, 0)
            let length = (room * share).rounded()
            let firstFrame: CGRect
            let secondFrame: CGRect
            if stacked {
                firstFrame = CGRect(x: area.minX, y: area.minY, width: area.width, height: length)
                secondFrame = CGRect(x: area.minX, y: firstFrame.maxY + gutter, width: area.width, height: room - length)
            } else {
                firstFrame = CGRect(x: area.minX, y: area.minY, width: length, height: area.height)
                secondFrame = CGRect(x: firstFrame.maxX + gutter, y: area.minY, width: room - length, height: area.height)
            }
            result.splits.append(CardSplitFrame(path: path, stacked: stacked, share: share, area: area,
                                                first: firstFrame, second: secondFrame))
            first.collect(in: firstFrame, gutter: gutter, path: path + [0], dragging: dragging, into: &result)
            second.collect(in: secondFrame, gutter: gutter, path: path + [1], dragging: dragging, into: &result)
        }
    }
}

/// How each pair of sessions last shared the area, kept as the part the pair's first session takes, the
/// two sorted by host and name. A pair never resized splits evenly. A session keeps its part whichever
/// card it sits in.
struct CardShares: Equatable {
    /// "host<tab>name<newline>host<tab>name", sorted, to the first one's part.
    private(set) var stored: [String: Double]

    /// The least and most of the room the first card takes.
    static let range: ClosedRange<CGFloat> = 0.25...0.75

    init(stored: [String: Double] = [:]) {
        self.stored = stored
    }

    static func clamped(_ share: CGFloat) -> CGFloat {
        min(max(share, range.lowerBound), range.upperBound)
    }

    /// The part `pair[0]` takes of the room it shares with `pair[1]`.
    func share(of pair: [SessionRef]) -> CGFloat {
        guard let (key, flipped) = Self.key(of: pair), let share = stored[key] else { return 0.5 }
        return flipped ? 1 - share : share
    }

    mutating func set(_ share: CGFloat, for pair: [SessionRef]) {
        guard let (key, flipped) = Self.key(of: pair) else { return }
        let share = Self.clamped(share)
        stored[key] = flipped ? 1 - share : share
    }

    /// The renamed session keeps its part beside each session it shared the area with.
    mutating func rename(_ ref: SessionRef, to renamed: SessionRef) {
        for (key, share) in stored {
            let pair = key.split(separator: "\n").compactMap { SessionRef(line: $0) }
            guard pair.contains(ref) else { continue }
            stored[key] = nil
            set(share, for: pair.map { $0 == ref ? renamed : $0 })
        }
    }

    /// Drops every pair the session was part of.
    mutating func forget(_ ref: SessionRef) {
        stored = stored.filter { key, _ in !key.split(separator: "\n").contains(Substring(ref.line)) }
    }

    private static func key(of pair: [SessionRef]) -> (key: String, flipped: Bool)? {
        guard pair.count == 2, pair[0] != pair[1] else { return nil }
        let lines = pair.map(\.line)
        let flipped = lines[0] > lines[1]
        return ((flipped ? lines.reversed() : lines).joined(separator: "\n"), flipped)
    }
}
