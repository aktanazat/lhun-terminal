import XCTest

/// Get File and dictation on a connected device, run through tools/files.sh, which makes the session, its
/// folder and the files in it, speaks for the dictation, photographs each step, and checks the hashes,
/// the files the shell wrote, and the footprint around each step.
final class LhunFiles: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The mic key listens, the bubble shows the words as they come, and the mic key again types them at
    /// the prompt, without Return. Esc and a tap away each drop what was heard. A simulator skips it.
    @MainActor
    func testDictating() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("dictation turns speech into text with SpeechTranscriber, which needs the Neural Engine a simulator does not have")
        #else
        let (app, probe) = try open()
        app.typeText("print -r -- '")
        let mic = app.buttons["key.dictate"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "no mic key on the key row")
        settle(probe)
        mic.tap()
        allowAlerts()
        let bubble = app.buttons["dictation.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "the dictation bubble never showed")
        XCTAssertTrue(
            bubble.wait(for: \.label, toEqual: "Listening…", timeout: 120),
            "dictation never started listening; the bubble read \(bubble.label.debugDescription)"
        )
        ask("dictation-listening")
        // tools/files.sh speaks through the Mac's speaker once asked.
        ask("say")
        let heard = NSPredicate(format: "value CONTAINS[c] %@", "lazy")
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: heard, evaluatedWith: bubble)], timeout: 30), .completed,
            "the bubble never showed the spoken words; it read \(String(describing: bubble.value).debugDescription)"
        )
        ask("dictation-words")
        mic.tap()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 15), "the bubble stayed after the mic key typed the words")
        XCTAssertNotEqual(mic.value as? String, "listening", "the mic key stayed lit after dictation ended")
        settle(probe)
        ask("dictation-typed")
        app.typeText("' >| dictated.txt\r")

        // Esc drops the words, and so does a tap away from the bubble; the shell writes only what was typed.
        app.typeText("print -r -- 'kept")
        mic.tap()
        XCTAssertTrue(bubble.wait(for: \.label, toEqual: "Listening…", timeout: 30), "dictation never listened again")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Esc left the bubble up")
        mic.tap()
        XCTAssertTrue(bubble.wait(for: \.label, toEqual: "Listening…", timeout: 30), "dictation never listened a third time")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "a tap away left the bubble up")
        app.typeText("' >| cancelled.txt\r")
        settle(probe)
        #endif
    }

    /// The picker in Get File mode lists the session's folder; a file chosen comes to the device and opens
    /// in Quick Look, with Share; one past 50 MB is refused with its size. A simulator skips it.
    @MainActor
    func testGettingAFile() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Get File shows what it gets in Quick Look, and a simulator's Quick Look leaves its close and Share buttons out of the accessibility hierarchy; the iPad runs this test")
        #else
        let (app, probe) = try open()
        // The picker's search field takes the keyboard the first time it opens, which keeps a few MB in
        // UIKit whatever the picker does next; once open and shut first, the previews are measured alone.
        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["paths.proof.png"].waitForExistence(timeout: 15), "the picker never listed proof.png")
        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["paths.proof.png"].waitForNonExistence(timeout: 5), "⌘⇧O left the picker open")
        settle(probe)
        app.typeKey("o", modifierFlags: [.command, .shift])
        let png = app.buttons["paths.proof.png"]
        XCTAssertTrue(png.waitForExistence(timeout: 15), "the picker never listed proof.png")
        XCTAssertFalse(app.buttons["paths./here"].exists, "Get File offered to use the folder")
        ask("get-file-picker")
        png.tap()
        preview(app, "get-file-png")
        settle(probe)

        app.typeKey("o", modifierFlags: [.command, .shift])
        let pdf = app.buttons["paths.proof.pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 15), "the picker never listed proof.pdf")
        pdf.tap()
        preview(app, "get-file-pdf")
        settle(probe)

        app.typeKey("o", modifierFlags: [.command, .shift])
        let big = app.buttons["paths.big.bin"]
        XCTAssertTrue(big.waitForExistence(timeout: 15), "the picker never listed big.bin")
        big.tap()
        let refused = app.staticTexts["That file is 60 MB. Lhûn gets files up to 50 MB."]
        XCTAssertTrue(refused.waitForExistence(timeout: 30), "a 60 MB file was not refused with its size")
        ask("get-file-too-large")
        app.alerts.buttons.firstMatch.tap()
        settle(probe)
        #endif
    }

    // MARK: Steps

    /// Launches Lhûn with the probe on and opens the session tools/files.sh made, attached.
    @MainActor
    private func open() throws -> (app: XCUIApplication, probe: XCUIElement) {
        let session = try XCTUnwrap(ProcessInfo.processInfo.environment["FILES_SESSION"], "run this test through tools/files.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac", "-probe", "YES"]
        app.launch()
        let probe = app.descendants(matching: .any)["probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never started")
        let row = app.descendants(matching: .any)["session.mac.\(session)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(session) never appeared")
        row.tap()
        XCTAssertTrue(app.textViews["terminal"].firstMatch.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
        return (app, probe)
    }

    /// Waits for Quick Look to show the file got, brings up its controls, checks they offer Share,
    /// photographs it, and closes it. Quick Look opens with its controls hidden; a tap shows them.
    @MainActor
    private func preview(_ app: XCUIApplication, _ name: String) {
        let shown = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(shown.waitForExistence(timeout: 30), "\(name): Quick Look never opened")
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        if !close.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5), "\(name): Quick Look showed no close button")
        XCTAssertTrue(app.buttons["Share"].exists, "\(name): the preview offered no Share")
        ask(name)
        close.tap()
        XCTAssertTrue(shown.waitForNonExistence(timeout: 10), "\(name): Quick Look never closed")
    }

    /// Taps Allow on the microphone and speech alerts the first run raises.
    @MainActor
    private func allowAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
                if allow.exists { allow.tap() }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Ten seconds of probe samples, for tools/files.sh to read the footprint once a step has let go.
    @MainActor
    private func settle(_ probe: XCUIElement) {
        let start = probeTime(probe)
        let deadline = Date.now.addingTimeInterval(20)
        while probeTime(probe) < start + 10, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertGreaterThanOrEqual(probeTime(probe), start + 10, "the probe stopped sampling")
    }

    @MainActor
    private func probeTime(_ probe: XCUIElement) -> Double {
        let sample = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any]
        return (sample?["t"] as? NSNumber)?.doubleValue ?? 0
    }

    /// Asks tools/files.sh for `name`, a screenshot or "say", and holds still until it answers. The test
    /// asks with an empty file named for it in its own Documents, and tools/files.sh answers with another.
    /// Other builders' scripts share this runner, so both names carry "files-", the only ones it answers.
    @MainActor
    private func ask(_ name: String) {
        let documents = URL.documentsDirectory
        let taken = documents.appending(path: "taken-files-\(name)").path(percentEncoded: false)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: documents.appending(path: "take-files-\(name)").path(percentEncoded: false), contents: nil),
            "could not ask for \(name)"
        )
        let deadline = Date.now.addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: taken), Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: taken), "tools/files.sh never answered \(name)")
    }
}
