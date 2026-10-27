import XCTest

/// Light-mode contrast correction on a real device (tools/contrast.sh). Two tmux sessions on the Mac
/// hold the fixtures: `contrast` prints pale truecolor and 256-color text, `contrast-bat` shows a file
/// in bat's dark Monokai theme. The run switches the device to light appearance, keeps a screenshot of
/// each, then switches back to dark (also when the test fails) and keeps the same two again.
/// One guard: in light mode, with corrected colors on screen, an idle session presents no frames.
final class LhunContrastShots: XCTestCase {
    @MainActor
    func testLightAndDarkScreens() throws {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.appearance = .dark }
        }
        XCUIDevice.shared.appearance = .light

        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-probe", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")

        try open(app, "contrast")
        sleep(5)
        keep(app, "light-pattern")
        let idleStart = try sample(probe)
        sleep(10)
        let idleEnd = try sample(probe)

        try open(app, "contrast-bat")
        sleep(5)
        keep(app, "light-bat")
        keep(probe.label, "probe-light")

        XCUIDevice.shared.appearance = .dark
        sleep(5)
        keep(app, "dark-bat")
        try open(app, "contrast")
        sleep(5)
        keep(app, "dark-pattern")

        XCTAssertEqual((idleEnd["frames"] ?? -1) - (idleStart["frames"] ?? 0), 0, "an idle light-mode session presented frames")
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ name: String) throws {
        let session = app.descendants(matching: .any)["session.mac.\(name)"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 30), "\(name) never appeared")
        session.tap()
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "\(name) never attached")
    }

    @MainActor
    private func sample(_ probe: XCUIElement) throws -> [String: Int] {
        let object = try JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func keep(_ text: String, _ name: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }
}
