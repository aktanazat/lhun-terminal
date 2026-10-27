import XCTest

/// The terminal's on-screen keyboard, as the UI tests see it. On an iPad, Lhûn's key row rides on the
/// keyboard while the terminal has it, and the row's Hide Keyboard button puts the keyboard down and goes
/// with it. A simulator reports a hardware keyboard to Lhûn (GameController sees one there), so Lhûn leaves
/// the key row off while the on-screen keyboard still comes up. There the keyboard's own Hide keyboard key
/// stands in, and since a keyboard put down stays in the hierarchy below the screen, it counts as up only
/// while that key can be tapped.
@MainActor
struct OnScreenKeyboard {
    let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    /// The button that puts the keyboard down.
    var hide: XCUIElement {
        #if targetEnvironment(simulator)
        app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'Hide keyboard'")).firstMatch
        #else
        app.buttons["Hide Keyboard"].firstMatch
        #endif
    }

    /// Whether the keyboard is up now.
    var isUp: Bool {
        #if targetEnvironment(simulator)
        hide.exists && hide.isHittable
        #else
        hide.exists
        #endif
    }

    /// Whether the keyboard is up within `seconds`.
    func up(within seconds: TimeInterval) -> Bool {
        holds(within: seconds) { isUp }
    }

    /// Whether the keyboard is down within `seconds`.
    func down(within seconds: TimeInterval) -> Bool {
        holds(within: seconds) { !isUp }
    }

    /// Puts the keyboard down if it is up within `seconds`, failing the test when it stays up, and returns
    /// whether it was up.
    @discardableResult
    func putDown(ifUpWithin seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard up(within: seconds) else { return false }
        hide.tap()
        XCTAssertTrue(down(within: 10), "the keyboard stayed up", file: file, line: line)
        return true
    }

    private func holds(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }
}
