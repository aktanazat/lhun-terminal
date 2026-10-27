import CoreGraphics
import Testing
@testable import LhunKit

/// Which of UIKit's reports of the keyboard's moves the cards make room for. The reports are the ones an
/// iPad Pro 11-inch gave, in the screen's space, as it turned upright with the keyboard up and back.
@MainActor
struct KeyboardMotionTests {
    static let upright = CGRect(x: 0, y: 0, width: 834, height: 1194)
    static let sideways = CGRect(x: 0, y: 0, width: 1194, height: 834)

    @Test("Turning, only where the keyboard ends up counts")
    func turning() {
        #expect(!KeyboardMotion.settles(CGRect(x: 0, y: 545, width: 834, height: 38), on: Self.upright, over: 0, accessoryHeight: 54))
        #expect(!KeyboardMotion.settles(CGRect(x: 0, y: 510, width: 834, height: 324), on: Self.upright, over: 0, accessoryHeight: 54))
        #expect(KeyboardMotion.settles(CGRect(x: 0, y: 838, width: 834, height: 356), on: Self.upright, over: 0, accessoryHeight: 54))
        #expect(!KeyboardMotion.settles(CGRect(x: 0, y: 796, width: 583, height: 38), on: Self.sideways, over: 0, accessoryHeight: 54))
        #expect(KeyboardMotion.settles(CGRect(x: 0, y: 393, width: 1194, height: 441), on: Self.sideways, over: 0, accessoryHeight: 54))
    }

    @Test("A keyboard put away at once counts")
    func goneAtOnce() {
        #expect(KeyboardMotion.settles(CGRect(x: 0, y: 834, width: 1194, height: 441), on: Self.sideways, over: 0, accessoryHeight: 54))
    }

    @Test("A turn's key-row-only report does not dismiss the keyboard")
    func accessoryDuringTurn() {
        let row = CGRect(x: 0, y: 1140, width: 834, height: 54)
        #expect(!KeyboardMotion.settles(row, on: Self.upright, over: 0, accessoryHeight: 54))
        #expect(!KeyboardMotion.settles(row, on: Self.sideways, over: 0, accessoryHeight: 54))
    }

    @Test("A timed dismissal to the key row still counts")
    func timedAccessory() {
        #expect(KeyboardMotion.settles(
            CGRect(x: 0, y: 1140, width: 834, height: 54), on: Self.upright, over: 0.25, accessoryHeight: 54
        ))
    }

    @Test("A report with no keyboard in it is not a keyboard move, timed or not")
    func emptyReport() {
        #expect(!KeyboardMotion.settles(.zero, on: Self.sideways, over: 0.25, accessoryHeight: 54))
        #expect(!KeyboardMotion.settles(.zero, on: Self.sideways, over: 0, accessoryHeight: 54))
        #expect(KeyboardMotion.settles(CGRect(x: 0, y: 834, width: 1194, height: 0), on: Self.sideways, over: 0.25, accessoryHeight: 54))
    }
}
