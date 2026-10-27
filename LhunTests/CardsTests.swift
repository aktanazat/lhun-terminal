import CoreGraphics
import Testing
@testable import LhunKit

/// Where a dropped pill opens its session, how two cards share the area, and how a pair keeps its share.
struct CardsTests {
    static let a = SessionRef(host: "mac", name: "a")
    static let b = SessionRef(host: "mac", name: "b")
    static let c = SessionRef(host: "mac", name: "c")

    @Test("A point opens on the half whose edge it is nearest, the area's diagonals parting them and a tie going across", arguments: [
        (CGPoint(x: 0.5, y: 0.92), Half.bottom),
        (CGPoint(x: 0.75, y: 0.55), Half.right),
        (CGPoint(x: 0.25, y: 0.55), Half.left),
        (CGPoint(x: 0.5, y: 0.08), Half.top),
        (CGPoint(x: 0.2, y: 0.15), Half.top),
        (CGPoint(x: 0.15, y: 0.2), Half.left),
        (CGPoint(x: 0.5, y: 0.5), Half.right),
    ])
    func nearestHalf(_ point: CGPoint, _ half: Half) {
        let size = CGSize(width: 1000, height: 500)
        #expect(Half(nearest: CGPoint(x: point.x * size.width, y: point.y * size.height), in: size) == half)
    }

    @Test("Two cards share the area less the gutter, with the first taking its share in whole points")
    func framesLeaveTheGutter() {
        let size = CGSize(width: 1178, height: 700)
        let across = CardLayout(stacked: false, share: 0.3)
        #expect(across.frames(count: 2, in: size) == [
            CGRect(x: 0, y: 0, width: 351, height: 700),
            CGRect(x: 359, y: 0, width: 819, height: 700),
        ])
        #expect(CardLayout(stacked: true, share: 0.65).frames(count: 2, in: size) == [
            CGRect(x: 0, y: 0, width: 1178, height: 450),
            CGRect(x: 0, y: 458, width: 1178, height: 242),
        ])
        #expect(across.frames(count: 1, in: size) == [CGRect(origin: .zero, size: size)])
    }

    @Test("A pair's share belongs to its two sessions, whichever card each sits in, and a pair never resized splits evenly")
    func shareFollowsTheSessions() {
        var shares = CardShares()
        shares.set(0.375, for: [Self.b, Self.a])
        #expect(shares.share(of: [Self.b, Self.a]) == 0.375)
        #expect(shares.share(of: [Self.a, Self.b]) == 0.625)
        #expect(shares.share(of: [Self.a, Self.c]) == 0.5)
        shares.set(0.9, for: [Self.a, Self.c])
        #expect(shares.share(of: [Self.a, Self.c]) == 0.75)
    }

    @Test("A renamed session keeps its share beside each session it shared the area with; a killed one's pairs go")
    func renamedKeepsItsShare() {
        var shares = CardShares()
        shares.set(0.375, for: [Self.a, Self.b])
        shares.set(0.625, for: [Self.b, Self.c])
        // z sorts after b, where a sorted before it.
        let z = SessionRef(host: "mac", name: "z")
        shares.rename(Self.a, to: z)
        #expect(shares.share(of: [z, Self.b]) == 0.375)
        #expect(shares.share(of: [Self.a, Self.b]) == 0.5)
        shares.forget(Self.c)
        #expect(shares.share(of: [Self.b, Self.c]) == 0.5)
        #expect(shares.share(of: [Self.b, z]) == 0.625)
    }
}
