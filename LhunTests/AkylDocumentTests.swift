import Foundation
import Testing
@testable import LhunKit

struct AkylDocumentTests {
    private static let token = "00000000-0000-4000-8000-000000000001"
    private static let open = """
    {"version":1,"token":"\(token)","task":"fixture-task","taskTitle":"Original task",
     "terminalPlace":{"host":"mac","session":"original-session","window":2},
     "frozenContext":{"source":{"item":"fixture-item","sourceAt":"2001-01-01T01:00:00.123+01:00","cardPath":[0,1],"revision":3,"task":"fixture-task"},
       "selectedAt":"2001-01-01T00:00:01.000Z","title":"Frozen detail","context":"Full original text\\nSecond line: λ",
       "captureConditions":{"scenario":"Original capture","device":"Fixture device","viewportWidth":400,"viewportHeight":800,"appearance":"dark","textSize":"Large","reduceMotion":true}}}
    """
    private static let digest = String(repeating: "Ab", count: 32)
    private static let quote = "First page: λ𝄞. Preserve UTF-16 units, not character counts.\n"
        + String(repeating: "Full neutral original quote, never a preview or shortened source. ", count: 12)
        + "\nSecond page: retain every original line."

    private static func request(version: Int, document: Bool = false, digest: String = Self.digest, rangeLength: Int = 7) throws -> Data {
        let open = Self.open.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)")
        guard document else { return Data(open.utf8) }
        let pdf = """
        {"revision":"\(digest)","blob":"fixture-original.pdf",
         "pages":[
           {"occurrence":"fixture-copy:2","number":2,
            "regions":[{"x":4.5,"y":8.25,"width":20.75,"height":12.5},{"x":48.125,"y":60.5,"width":70.25,"height":80.75}],
            "ranges":[{"location":4,"length":\(rangeLength)},{"location":15,"length":9}]},
           {"occurrence":"fixture-original:1","number":1,
            "regions":[{"x":12,"y":24,"width":36,"height":48}],"ranges":[{"location":2,"length":3}]}],
         "quote":\(String(decoding: try JSONEncoder().encode(quote), as: UTF8.self))}
        """
        return Data(open.replacingOccurrences(of: "\"frozenContext\":{", with: "\"frozenContext\":{\"document\":\(pdf),").utf8)
    }

    @Test("Frozen evidence stays an object with its source, complete text and original capture conditions")
    func frozenEvidence() throws {
        let original = try AkylDocument.decoder().decode(AkylTaskContext.self, from: Data(Self.open.utf8))
        let encoder = AkylDocument.encoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(original)
        let restored = try AkylDocument.decoder().decode(AkylTaskContext.self, from: encoded)
        #expect(try encoder.encode(restored) == encoded)
        #expect(restored.frozenContext?.context == "Full original text\nSecond line: λ")
        let sourceTime = try #require(restored.frozenContext?.source.sourceAt.timeIntervalSinceReferenceDate)
        #expect(abs(sourceTime - 0.123) < 0.000001)
        #expect(restored.frozenContext?.captureConditions?.viewportWidth == 400)
        #expect(restored.frozenContext?.captureConditions?.viewportHeight == 800)
        #expect(restored.frozenContext?.captureConditions?.reduceMotion == true)
    }

    @Test("Normal Back keeps its originating version and token only", arguments: [1, 2])
    func normalBack(version: Int) throws {
        let context = try AkylDocument.decoder().decode(AkylTaskContext.self, from: Self.request(version: version))
        let returned = AkylTaskReturn.capturing(" \n\t", context: context, host: "mac", session: "actual-session", at: Date())
        let encoded = try AkylDocument.encoder().encode(returned)
        #expect(try AkylDocument.decoder().decode(Keys.self, from: encoded).names == ["version", "token"])
        #expect(try AkylDocument.decoder().decode(AkylTaskReturn.self, from: encoded) == .back(version: context.version, token: Self.token))
    }

    @Test("Selected return is flat, retains full text, and identifies its actual different session", arguments: [1, 2])
    func selectedReturn(version: Int) throws {
        let json = """
        {"version":\(version),"token":"\(Self.token)","selectedText":"Full selection\\nSecond line: λ𝄞","host":"server","session":"actual-selected-session","capturedAt":"2001-01-01T00:00:02.123Z"}
        """
        let returned = try AkylDocument.decoder().decode(AkylTaskReturn.self, from: Data(json.utf8))
        let encoded = try AkylDocument.encoder().encode(returned)
        #expect(try AkylDocument.decoder().decode(Keys.self, from: encoded).names == ["version", "token", "selectedText", "host", "session", "capturedAt"])
        #expect(returned.version.rawValue == version)
        #expect(returned.selected?.text == "Full selection\nSecond line: λ𝄞")
        #expect(returned.selected?.session == "actual-selected-session")
        #expect(try AkylDocument.decoder().decode(AkylTaskReturn.self, from: encoded) == returned)
    }

    @Test("A partial selection never turns into a normal Back or an invented source")
    func partialSelection() {
        let json = """
        {"version":1,"token":"\(Self.token)","selectedText":"Keep me","host":"mac"}
        """
        #expect(throws: AkylDocument.Failure.self) {
            try AkylDocument.decoder().decode(AkylTaskReturn.self, from: Data(json.utf8))
        }
    }

    @Test("Unknown document versions do not silently use the current task")
    func unknownVersion() {
        let json = """
        {"version":3,"token":"\(Self.token)","task":"fixture-task","taskTitle":"Original task","terminalPlace":{"host":"mac","session":"original-session"}}
        """
        #expect(throws: AkylDocument.Failure.self) {
            try AkylDocument.decoder().decode(AkylTaskContext.self, from: Data(json.utf8))
        }
    }

    @Test("A pending excerpt survives attempted replacement and cold restoration, including unknown OS acceptance", arguments: [1, 2])
    func retainedSelection(version: Int) throws {
        let context = try AkylDocument.decoder().decode(AkylTaskContext.self, from: Self.request(version: version, document: version == 2))
        var visit = AkylVisit(context: context, previous: .init(host: "mac", panes: [], selection: nil, stacked: false, zoomed: nil, shares: [:]))
        let original = AkylTaskReturn.capturing("Full selected text\nKeep this line", context: context, host: "server", session: "actual-session", at: Date(timeIntervalSinceReferenceDate: 2))
        let staged = visit.stage(original)
        let replacedByBack = visit.stage(.back(version: context.version, token: context.token))
        let replacedByOtherTask = visit.stage(.back(version: context.version, token: "00000000-0000-4000-8000-000000000002"))
        #expect(staged)
        #expect(!replacedByBack)
        #expect(!replacedByOtherTask)
        visit.recipient = "fixture.os.recipient"
        visit.deliveryNote = "OS delivery; task acceptance unknown"
        let restored = try AkylDocument.decoder().decode(AkylVisit.self, from: AkylDocument.encoder().encode(visit))
        #expect(restored.pending == original)
        let encoder = AkylDocument.encoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(restored.context) == encoder.encode(context))
        #expect(restored.recipient == "fixture.os.recipient")
    }

    @Test("V2 preserves the complete original PDF locator without changing order, points, UTF-16 units or quote")
    func frozenDocument() throws {
        let context = try AkylDocument.decoder().decode(AkylTaskContext.self, from: Self.request(version: 2, document: true))
        let document = try #require(context.frozenContext?.document)
        #expect(document.revision == Self.digest)
        #expect(document.blob == "fixture-original.pdf")
        #expect(document.pages.map(\.occurrence) == ["fixture-copy:2", "fixture-original:1"])
        #expect(document.pages.map(\.number) == [2, 1])
        #expect(document.pages[0].regions == [
            .init(x: 4.5, y: 8.25, width: 20.75, height: 12.5),
            .init(x: 48.125, y: 60.5, width: 70.25, height: 80.75)
        ])
        #expect(document.pages[0].ranges == [.init(location: 4, length: 7), .init(location: 15, length: 9)])
        #expect(document.quote == Self.quote)
        let encoder = AkylDocument.encoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(context)
        let restored = try AkylDocument.decoder().decode(AkylTaskContext.self, from: encoded)
        #expect(restored.frozenContext?.document == document)
        #expect(try encoder.encode(restored) == encoded)
    }

    @Test("V1 refuses a PDF context rather than exporting a shortened copy")
    func v1RefusesDocument() throws {
        let bytes = try Self.request(version: 1, document: true)
        #expect(throws: AkylDocument.Failure.self) {
            try AkylDocument.decoder().decode(AkylTaskContext.self, from: bytes)
        }
    }

    @Test("A frozen PDF locator requires a complete hexadecimal digest", arguments: [
        String(repeating: "Ab", count: 31), "g" + String(repeating: "a", count: 63)
    ])
    func invalidDocumentDigest(digest: String) throws {
        let bytes = try Self.request(version: 2, document: true, digest: digest)
        #expect(throws: AkylDocument.Failure.self) {
            try AkylDocument.decoder().decode(AkylTaskContext.self, from: bytes)
        }
    }

    @Test("Invalid and overflowing UTF-16 ranges cannot replace complete frozen PDF context", arguments: [0, Int.max])
    func invalidDocumentRange(length: Int) throws {
        let bytes = try Self.request(version: 2, document: true, rangeLength: length)
        #expect(throws: AkylDocument.Failure.self) {
            try AkylDocument.decoder().decode(AkylTaskContext.self, from: bytes)
        }
    }

    @Test("The original token alone cannot stage a different request version", arguments: [1, 2])
    func wrongRequestVersion(version: Int) throws {
        let context = try AkylDocument.decoder().decode(AkylTaskContext.self, from: Self.request(version: version, document: version == 2))
        var visit = AkylVisit(context: context, previous: .init(host: "mac", panes: [], selection: nil, stacked: false, zoomed: nil, shares: [:]))
        let wrong: AkylTaskReturn = .back(version: version == 1 ? .v2 : .v1, token: context.token)
        let stagedWrong = visit.stage(wrong)
        #expect(!stagedWrong)
        #expect(visit.pending == nil)
        let correct = AkylTaskReturn.capturing("Actual terminal text, not a PDF selection", context: context, host: "server", session: "actual-session", at: Date(timeIntervalSinceReferenceDate: 2))
        let stagedCorrect = visit.stage(correct)
        #expect(stagedCorrect)
        #expect(visit.pending == correct)
    }

    private struct Keys: Decodable {
        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        let names: Set<String>
        init(from decoder: Decoder) throws {
            names = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
        }
    }
}
