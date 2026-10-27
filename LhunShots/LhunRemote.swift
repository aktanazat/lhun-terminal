import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Drives the preview and paste upload on a real device against the Mac. tools/remote.sh serves a page
/// naming this run's nonce on the Mac's localhost:8765, runs these, and then checks the Mac's side: the
/// server's log, what is still connected to the port, and each uploaded file against the bytes this
/// runner copied.
final class LhunRemote: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// An address printed in a session opens in the preview through a port on this device's loopback,
    /// which carries any client's connection to the Mac; closing the preview stops that port listening
    /// and closes every connection through it.
    @MainActor
    func testPreview() throws {
        let nonce = try setting("LHUN_NONCE")
        let proofFolder = try setting("LHUN_PROOF_DIR")
        let (app, terminal) = try openSession()

        // An address on screen is offered in the palette, and in the port prompt.
        app.typeText("clear; echo http://localhost:8765/\n")
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), "the palette never opened")
        query.typeText("preview")
        XCTAssertTrue(app.buttons["palette.preview.8765"].waitForExistence(timeout: 5), "the address on screen was not offered")
        app.buttons["palette.preview"].tap()
        let portField = app.alerts.textFields.firstMatch
        XCTAssertTrue(portField.waitForExistence(timeout: 5), "the port prompt never opened")
        XCTAssertEqual(portField.value as? String, "8765", "the prompt did not offer the port on screen")
        app.alerts.buttons["Open"].tap()

        let heading = app.webViews.staticTexts["Lhun preview \(nonce)"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "the page served on the Mac never loaded")
        keep("preview")

        // The forwarded port carries any client's connection to the Mac, not only the preview's own.
        let address = app.descendants(matching: .any)["preview.address"].firstMatch
        let value = try XCTUnwrap(address.value as? String)
        let localPort = try XCTUnwrap(URLComponents(string: value)?.port, "no port in \(value)")
        let page = try XCTUnwrap(Loopback.connect(to: localPort), "nothing listened on \(localPort) during the preview")
        defer { Darwin.close(page) }
        XCTAssertTrue(Loopback.get(page).contains("Lhun preview \(nonce)"), "a request through \(localPort) did not reach the Mac's page")

        // Closing the preview closes a connection still open through it, and stops it listening.
        let held = try XCTUnwrap(Loopback.connect(to: localPort), "nothing listened on \(localPort) during the preview")
        defer { Darwin.close(held) }
        app.buttons["preview.close"].tap()
        XCTAssertTrue(Loopback.closedByPeer(held, within: 10), "a connection through the preview outlived it")
        XCTAssertNil(Loopback.connect(to: localPort).map { Darwin.close($0) }, "port \(localPort) still listened after the preview closed")

        // The Mac's view of the same moment, while Lhûn is still running: tools/remote.sh reads it.
        terminal.tap()
        app.typeText("clear; lsof -nP -iTCP:8765 > \(proofFolder)/after-close.txt\n")
    }

    /// PNG bytes another app copied, pasted at the prompt, go to the Mac as they are, and their path is
    /// typed there. Lhûn shows it is uploading until then.
    @MainActor
    func testPastedImageData() throws {
        let png = try Noise.png(side: 2400)
        try pasteUpload("data") {
            UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
            return png
        }
    }

    /// An image another app copied as an image goes to the Mac the same way, as the clipboard's PNG of it.
    @MainActor
    func testPastedImage() throws {
        let image = UIImage(cgImage: try Noise.image(side: 2400))
        try pasteUpload("image") {
            UIPasteboard.general.image = image
            return try XCTUnwrap(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier), "the copied image has no PNG")
        }
    }

    /// A file another app copied as a file goes to the Mac as it is, under its own name.
    @MainActor
    func testPastedFile() throws {
        let png = try Noise.png(side: 2400)
        let file = FileManager.default.temporaryDirectory.appending(path: "lhun-copied-file.png")
        try png.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try pasteUpload("file") {
            UIPasteboard.general.itemProviders = [try XCTUnwrap(NSItemProvider(contentsOf: file))]
            return png
        }
    }

    /// Text on the clipboard is typed at the prompt, and nothing is uploaded.
    @MainActor
    func testPastedText() throws {
        try skipPastingOnASimulator()
        let nonce = try setting("LHUN_NONCE")
        let proofFolder = try setting("LHUN_PROOF_DIR")
        let (app, terminal) = try openSession()
        try copy(in: app) {
            UIPasteboard.general.string = "print -r -- lhun-text-\(nonce) > \(proofFolder)/pasted-text.txt"
        }
        terminal.tap()
        // The host's uploads before the paste and once an upload would have landed, for tools/remote.sh.
        app.typeText("clear; ls ~/.cache/lhun/uploads > \(proofFolder)/uploads-before-text.txt\n")
        app.typeText("clear; ")
        app.typeKey("v", modifierFlags: .command)
        XCTAssertFalse(uploading(in: app).exists, "pasting text started an upload")
        app.typeText("; sleep 2; ls ~/.cache/lhun/uploads > \(proofFolder)/uploads-after-text.txt\n")
    }

    /// A file on its way keeps going while Lhûn leaves the screen and comes back, which drops the
    /// connection the session list uses. The file is big enough to still be on its way by then.
    @MainActor
    func testUploadOutlivesLeaving() throws {
        let png = try Noise.png(side: 3800)
        try pasteUpload("back", whileUploading: { app in
            XCTAssertTrue(self.uploading(in: app).exists, "the upload finished before Lhûn left, which proves nothing")
            XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier)).activate()
            app.activate()
        }) {
            UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
            return png
        }
    }

    /// On a simulator XCTest's Command-V pastes nothing into Lhûn, neither text nor files, though the same
    /// tests pass on the iPad, so the paste tests skip there.
    private func skipPastingOnASimulator() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("on a simulator XCTest's Command-V pastes nothing into Lhûn, text or files; the iPad runs this test")
        #endif
    }

    /// Copies with `write`, pastes at a prompt that saves the typed path for tools/remote.sh, and keeps
    /// the bytes copied beside the run's screenshots, for the Mac to compare with what arrived.
    /// `whileUploading` runs once Lhûn shows the upload.
    @MainActor
    private func pasteUpload(
        _ name: String,
        whileUploading: (XCUIApplication) throws -> Void = { _ in },
        copying write: () throws -> Data
    ) throws {
        try skipPastingOnASimulator()
        let proofFolder = try setting("LHUN_PROOF_DIR")
        let (app, terminal) = try openSession()
        let copied = XCTAttachment(data: try copy(in: app, write), uniformTypeIdentifier: UTType.png.identifier)
        copied.name = "copied-\(name)"
        copied.lifetime = .keepAlways
        add(copied)

        terminal.tap()
        app.typeText("clear; print -r -- ")
        app.typeKey("v", modifierFlags: .command)
        let uploading = uploading(in: app)
        XCTAssertTrue(uploading.waitForExistence(timeout: 15), "pasting started no upload")
        keep("pasted-\(name)")
        try whileUploading(app)
        XCTAssertTrue(uploading.waitForNonExistence(timeout: 120), "the upload never finished")
        let problem = app.alerts["That didn't work"]
        XCTAssertFalse(problem.exists, "the upload failed: \(problem.staticTexts.allElementsBoundByIndex.map(\.label))")
        app.typeText("> \(proofFolder)/typed-\(name).txt\n")
    }

    /// Launches Lhûn into the session tools/remote.sh made, attached, with the terminal taking keys.
    @MainActor
    private func openSession() throws -> (app: XCUIApplication, terminal: XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-keySeen", "YES", "-selection", "", "-workspaces", "", "-panes", "", "-host", "mac"]
        app.launch()
        let row = app.descendants(matching: .any)["session.mac.lhun-test-upload-shell"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the lhun-test-upload-shell session never appeared")
        row.tap()
        let terminal = app.textViews["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal opened")
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached")
        terminal.tap()
        return (app, terminal)
    }

    /// Runs `write` with this runner on screen, the way another app copies: iOS keeps what an app puts on
    /// the clipboard only while that app is in front. Lhûn comes back once it is done, attached as before.
    @MainActor
    @discardableResult
    private func copy<Copied>(in app: XCUIApplication, _ write: () throws -> Copied) throws -> Copied {
        XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier)).activate()
        let copied = try write()
        app.activate()
        XCTAssertTrue(app.staticTexts["status"].waitForNonExistence(timeout: 30), "the session never attached again")
        return copied
    }

    /// Lhûn's status line while a paste is on its way to the host.
    @MainActor
    private func uploading(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'status' AND label == %@", "Uploading…")).firstMatch
    }

    private func setting(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name], "run this through tools/remote.sh")
    }

    /// The whole screen: an app's own screenshot is cut to its frame in the wrong orientation when the
    /// iPad is held sideways. tools/remote.sh turns these the way the iPad is held.
    @MainActor
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Pictures of random pixels. Noise does not compress, so a PNG of it stays megabytes in size and takes
/// long enough to send that Lhûn's upload status is on screen for a while.
private enum Noise {
    static func image(side: Int) throws -> CGImage {
        var pixels = Data(count: side * side * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        return try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    static func png(side: Int) throws -> Data {
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(side: side), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "the noise PNG was not written")
        return png as Data
    }
}

/// Plain TCP on this device's loopback, the way any browser or tool would reach the preview's port.
private enum Loopback {
    /// Connects to 127.0.0.1, or returns nil when nothing listens on the port.
    static func connect(to port: Int) -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            return nil
        }
        return socket
    }

    /// Sends a GET for / and returns everything that comes back before the server closes, or what
    /// came within 10 seconds.
    static func get(_ socket: Int32) -> String {
        let request = Array("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)
        guard send(socket, request, request.count, 0) == request.count else { return "" }
        setReceiveTimeout(socket, seconds: 10)
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            response += buffer[..<count]
        }
        return String(decoding: response, as: UTF8.self)
    }

    /// Waits up to `seconds` for the other end to close the connection.
    static func closedByPeer(_ socket: Int32, within seconds: Int) -> Bool {
        setReceiveTimeout(socket, seconds: seconds)
        var byte: UInt8 = 0
        let count = recv(socket, &byte, 1, 0)
        return count == 0 || (count < 0 && errno != EAGAIN)
    }

    private static func setReceiveTimeout(_ socket: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
