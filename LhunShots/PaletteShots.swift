import UIKit
import XCTest

/// The command palette on a real device, for tools/palette.sh. ⌘K opens it and closes it five times, then
/// three typed letters narrow it and five presses of the down arrow move its highlight. The probe times each
/// step from its key going down to the frame that shows it ("palette" lines), and tools/palette.sh sums them
/// up. Pictures of the palette as it opens and once narrowed are kept, as the screen stands. The session the
/// test opens first, lhun-test-palette-speed, is tools/palette.sh's, killed afterwards.
///
/// ⌘K only comes from a hardware keyboard, while XCTest plugs one in for each key it types and pulls it out
/// again a moment later: the on-screen keyboard is back between keys a second apart, and drops as the next
/// key goes down, which would be timed with it. So a Shift press, which types nothing, plugs the keyboard in
/// ahead of each timed run of keys, and the on-screen keyboard has settled out of the way before them.
final class PaletteShots: XCTestCase {
    private static let fixture = "lhun-test-palette-speed"
    /// Which way Lhûn's interface stands, as UIInterfaceOrientation's raw value, from the probe at launch.
    private var interfaceOrientation = 0

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenNarrowAndMove() throws {
        let app = XCUIApplication()
        // Pills along the top whatever layout the device keeps, so the session's pill is there to tap.
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES", "-layout", "tabs"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let sample = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        interfaceOrientation = sample?["orientation"] as? Int ?? 0
        try open(app, Self.fixture)

        let query = app.textFields["palette.query"]
        for _ in 0..<5 {
            plugInKeyboard(app)
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette")
            sleep(1)
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(query.waitForNonExistence(timeout: 10), "⌘K left the palette open")
            sleep(1)
        }

        plugInKeyboard(app)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 10), "⌘K never opened the palette")
        sleep(2)
        keep("01-palette")
        plugInKeyboard(app)
        for letter in ["n", "e", "w"] {
            app.typeKey(letter, modifierFlags: [])
            usleep(500_000)
        }
        XCTAssertEqual(query.value as? String, "new", "the typed letters never reached the palette")
        sleep(1)
        keep("02-palette-new")
        plugInKeyboard(app)
        for _ in 0..<5 {
            app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
            usleep(500_000)
        }
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForNonExistence(timeout: 10), "⌘K left the palette open")
        // The probe writes its line a frame after the last step.
        sleep(1)
    }

    /// Opens the session with its pill and waits for it to attach, then presses one key that types
    /// nothing: XCUITest's first key after a launch can go astray.
    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        let session = app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 30), "\(name) never appeared; tools/palette.sh makes it")
        session.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
        terminal.tap()
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sleep(2)
    }

    /// Plugs in XCTest's hardware keyboard with a Shift press and waits for the on-screen keyboard to drop. A
    /// key typed while it still slides away waits for it, as long as 130 ms after a wait of 400 ms, so the wait
    /// is 800 ms, still short of the second after which the on-screen keyboard comes back.
    @MainActor
    private func plugInKeyboard(_ app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        usleep(800_000)
    }

    /// Keeps a screenshot of the whole screen in the result; tools/palette.sh copies out the numbered ones.
    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image))
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// XCTest takes the screen as the panel lies, in portrait, while Lhûn stands in landscape; this turns
    /// the picture the way the interface stands, as the probe reported at launch.
    @MainActor
    private func upright(_ screen: UIImage) -> UIImage {
        let turn: UIImage.Orientation
        switch UIInterfaceOrientation(rawValue: interfaceOrientation) {
        case .landscapeRight: turn = .left
        case .landscapeLeft: turn = .right
        default: return screen
        }
        guard screen.size.width < screen.size.height, let pixels = screen.cgImage else { return screen }
        let turned = UIImage(cgImage: pixels, scale: screen.scale, orientation: turn)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in turned.draw(at: .zero) }
    }
}
