import XCTest

extension XCTestCase {
    /// Turns Settings > Accessibility > Motion > Reduce Motion on or off, then quits Settings so it holds no
    /// keyboard focus or window into the next test.
    @MainActor
    func switchReduceMotion(_ on: Bool) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let toggle = settings.switches["Reduce Motion"].firstMatch
        if !toggle.waitForExistence(timeout: 4) {
            let accessibility = settings.staticTexts["Accessibility"].firstMatch
            XCTAssertTrue(accessibility.waitForExistence(timeout: 10), "Settings shows no Accessibility")
            for _ in 0..<8 where !accessibility.isHittable {
                settings.collectionViews.firstMatch.swipeUp()
            }
            accessibility.tap()
            let motion = settings.staticTexts["Motion"].firstMatch
            XCTAssertTrue(motion.waitForExistence(timeout: 10), "Accessibility shows no Motion")
            motion.tap()
        }
        guard toggle.waitForExistence(timeout: 10) else {
            let tree = XCTAttachment(string: settings.debugDescription)
            tree.name = "settings"
            add(tree)
            return XCTFail("Settings never showed the Reduce Motion switch")
        }
        let wanted = on ? "1" : "0"
        if toggle.value as? String != wanted {
            // The switch itself sits at the row's right end.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let deadline = Date.now.addingTimeInterval(5)
        while toggle.value as? String != wanted, Date.now < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertEqual(toggle.value as? String, wanted, "Reduce Motion")
        settings.terminate()
    }
}
