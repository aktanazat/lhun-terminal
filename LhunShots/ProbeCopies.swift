import CryptoKit
import XCTest

/// A copy Lhûn made to the device's clipboard, as its probe reports it: how many copies it had made since
/// launch, and the size and SHA-256 of the text the clipboard held right after, in UTF-8. The test runner
/// cannot read the device's clipboard, so the app reads it back the moment it copies.
struct ProbeCopy: Equatable, CustomStringConvertible {
    let count: Int
    let bytes: Int
    let sha256: String

    var description: String { "copy \(count): \(bytes) bytes, SHA-256 \(sha256)" }
}

extension XCTestCase {
    /// The latest copy Lhûn made, from the probe's latest sample; nil before its first since launch.
    @MainActor
    func copied(_ probe: XCUIElement) -> ProbeCopy? {
        guard let sample = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
              let copy = sample["copy"] as? [String: Any],
              let count = (copy["count"] as? NSNumber)?.intValue,
              let bytes = (copy["bytes"] as? NSNumber)?.intValue,
              let sha256 = copy["sha256"] as? String
        else { return nil }
        return ProbeCopy(count: count, bytes: bytes, sha256: sha256)
    }

    /// Waits for Lhûn to copy again after `before`, then checks the device's clipboard held exactly `text`.
    @MainActor
    func assertCopied(
        _ text: String, probe: XCUIElement, since before: ProbeCopy?, after action: String,
        timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line
    ) {
        let earlier = before?.count ?? 0
        let deadline = Date.now.addingTimeInterval(timeout)
        var latest = copied(probe)
        while (latest?.count ?? 0) <= earlier, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            latest = copied(probe)
        }
        guard let latest, latest.count > earlier else {
            XCTFail("\(action) put nothing on the clipboard", file: file, line: line)
            return
        }
        let expected = Data(text.utf8)
        let sha256 = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            latest, ProbeCopy(count: latest.count, bytes: expected.count, sha256: sha256),
            "what the clipboard held after \(action), against the \(expected.count) bytes of \"\(text)\"",
            file: file, line: line
        )
    }
}
