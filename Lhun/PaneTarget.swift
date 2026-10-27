import Foundation
import UniformTypeIdentifiers

struct PaneTarget: Codable, Equatable, Sendable {
    let ref: SessionRef
    let window: String
    let pane: String

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .lhunPaneTarget, visibility: .ownProcess) { load in
            do { load(try JSONEncoder().encode(self), nil) }
            catch { load(nil, error) }
            return nil
        }
        return provider
    }
}

extension UTType {
    static let lhunPaneTarget = UTType(exportedAs: "com.aktanazat.lhun.pane-target", conformingTo: .item)
}

struct TerminalDrop {
    enum Target: Equatable, Sendable {
        case pane(PaneTarget)
        case session(SessionRef)
    }

    static let types: [UTType] = [.lhunPaneTarget, .lhunSession]

    private let provider: NSItemProvider
    private let type: UTType

    init?(providers: [NSItemProvider]) {
        for type in Self.types {
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { continue }
            self.provider = provider
            self.type = type
            return
        }
        return nil
    }

    @MainActor
    func target() async -> Target? {
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        if type == .lhunPaneTarget {
            guard let pane = try? JSONDecoder().decode(PaneTarget.self, from: data) else { return nil }
            return .pane(pane)
        }
        guard let ref = SessionRef(line: String(decoding: data, as: UTF8.self)) else { return nil }
        return .session(ref)
    }
}
