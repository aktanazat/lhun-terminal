import SwiftUI
import Testing
import UIKit
@testable import LhunKit

/// What a session's attention mark draws. Working is the usual state, so a working session draws nothing
/// at all and nothing turns while an agent works for hours; a session he has not seen since it finished or
/// started to wait on him gets one still dot, the same for both.
@MainActor
struct IdleMotionTests {
    @Test("A working session draws nothing, and an unseen one an 8-point dot", arguments: [
        (AttentionBoard.Mark.working, CGSize.zero),
        (.finished, CGSize(width: 8, height: 8)),
        (.needsYou, CGSize(width: 8, height: 8)),
    ])
    func drawnSize(mark: AttentionBoard.Mark, expected: CGSize) {
        let drawn = UIHostingController(rootView: AttentionMark(mark: mark))
            .sizeThatFits(in: CGSize(width: 100, height: 100))
        #expect(drawn == expected)
    }

    @Test("The dot is the primary text color, whether the session finished or needs him",
          arguments: [AttentionBoard.Mark.finished, .needsYou], [ColorScheme.light, .dark])
    func dotColor(mark: AttentionBoard.Mark, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: AttentionMark(mark: mark).environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = try rgba(image)
        let middle = (image.height / 2 * image.width + image.width / 2) * 4
        // The primary text color is black in light and white in dark.
        let ink: UInt8 = scheme == .dark ? 255 : 0
        #expect(Array(pixels[middle..<middle + 4]) == [ink, ink, ink, 255])
    }
}
