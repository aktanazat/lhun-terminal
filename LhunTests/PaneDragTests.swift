import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LhunKit

@MainActor
struct PaneDragTests {
    private static let ref = SessionRef(host: "mac", name: "work")

    @Test("A background activity pane takes precedence over session and file representations", arguments: [
        ("@8", "%32"),
        ("@9", "%33"),
    ])
    func backgroundPaneSurvivesTheDrop(_ window: String, _ pane: String) async throws {
        let report = PaneReport(
            session: Self.ref.name, window: window, windowIndex: 2, windowBell: false, isShown: false,
            command: "omp", path: "/src/private", alternateScreen: false, progress: .none,
            title: "Fix login", model: "gpt-6", pane: pane
        )
        let row = TerminalActivity(ref: Self.ref, pane: report, folder: report.path, selected: Self.ref)
        let provider = row.itemProvider()
        let drop = try #require(TerminalDrop(providers: [Self.ref.itemProvider(), fileProvider(), provider]))

        #expect(await drop.target() == .pane(PaneTarget(ref: Self.ref, window: window, pane: pane)))
        #expect(provider.registeredContentTypes == [.lhunPaneTarget])
        #expect(Upload.files(in: [provider]).isEmpty)
        #expect(!UTType.lhunPaneTarget.conforms(to: .data))
    }

    @Test("An activity row without a pane keeps the existing session drag format and destination")
    func fallbackRowRemainsASessionDrop() async throws {
        let session = TmuxSession(
            name: Self.ref.name, windows: 2, window: 0, lastActivity: Date(timeIntervalSinceReferenceDate: 0),
            command: "zsh", folder: "~", model: ""
        )
        let row = TerminalActivity(ref: Self.ref, session: session, selected: nil)
        let provider = row.itemProvider()
        let drop = try #require(TerminalDrop(providers: [fileProvider(), provider]))
        let data = try #require(await representation(of: provider, as: .lhunSession))

        #expect(await drop.target() == .session(Self.ref))
        #expect(String(decoding: data, as: UTF8.self) == "mac\twork")
        #expect(provider.registeredContentTypes == [.lhunSession])
        #expect(Upload.files(in: [provider]).isEmpty)
    }

    @Test("A pane representation wins even when the same provider also carries a session and a file")
    func paneRepresentationWinsWithinOneProvider() async throws {
        let target = PaneTarget(ref: Self.ref, window: "@9", pane: "%33")
        let provider = target.itemProvider()
        provider.registerDataRepresentation(for: .lhunSession, visibility: .ownProcess) { load in
            load(Data("server\tother".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(for: .png, visibility: .all) { load in
            load(Data([0x89, 0x50, 0x4E, 0x47]), nil)
            return nil
        }
        let drop = try #require(TerminalDrop(providers: [provider]))

        #expect(await drop.target() == .pane(target))
    }

    @Test("An unreadable pane payload cannot become a session or file drop")
    func malformedPaneDoesNotFallThrough() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .lhunPaneTarget, visibility: .ownProcess) { load in
            load(Data("not a pane target".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(for: .png, visibility: .all) { load in
            load(Data([0x89, 0x50, 0x4E, 0x47]), nil)
            return nil
        }
        let drop = try #require(TerminalDrop(providers: [Self.ref.itemProvider(), provider]))

        #expect(await drop.target() == nil)
    }

    @Test("An external file stays a file and never becomes a terminal destination")
    func fileHandlingIsUnchanged() {
        let provider = fileProvider()

        #expect(TerminalDrop(providers: [provider]) == nil)
        #expect(Upload.files(in: [provider]) == [provider])
        #expect(Upload.format(of: provider) == .png)
    }

    private func fileProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .png, visibility: .all) { load in
            load(Data([0x89, 0x50, 0x4E, 0x47]), nil)
            return nil
        }
        return provider
    }

    private func representation(of provider: NSItemProvider, as type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
