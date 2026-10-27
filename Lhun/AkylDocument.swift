import Foundation

/// Akyl owns these document types and the task. Lhûn keeps only the imported snapshot and its return.
enum AkylDocument {
    static let contextType = "com.aktanazat.akyl.task-context"
    static let returnType = "com.aktanazat.akyl.task-return"

    enum Failure: Error { case version, token, target, selection, document, date, unreadable }

    enum Version: Int, Codable, Sendable {
        case v1 = 1, v2 = 2

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(Int.self)
            guard let version = Self(rawValue: value) else { throw Failure.version }
            self = version
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if text.count == 10, let date = try? Date(text, strategy: .iso8601.year().month().day()) { return date }
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            throw Failure.date
        }
        return decoder
    }

    /// The selected document may be an ordinary inbox copy or a security-scoped provider URL.
    static func read(_ url: URL) throws -> AkylTaskContext {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var read: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            read = Result { try Data(contentsOf: readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let read else { throw Failure.unreadable }
        return try decoder().decode(AkylTaskContext.self, from: read.get())
    }
}

struct AkylTaskContext: Codable, Equatable, Sendable {
    let version: AkylDocument.Version
    /// Keep the issued spelling, not a normalized UUID used as a different lookup key.
    let token: String
    let task: String
    let taskTitle: String
    let terminalPlace: TerminalPlace
    let frozenContext: EvidenceSelection?

    struct TerminalPlace: Codable, Equatable, Sendable {
        let host: String
        let session: String
        let window: Int?
    }

    struct EvidenceSelection: Codable, Equatable, Sendable {
        struct Source: Codable, Equatable, Sendable {
            let item: String
            let sourceAt: Date
            let cardPath: [Int]
            let revision: Int?
            let task: String?
        }
        struct Conditions: Codable, Equatable, Sendable {
            enum Appearance: String, Codable, Sendable { case light, dark }
            let scenario: String
            let device: String
            let viewportWidth: Double
            let viewportHeight: Double
            let appearance: Appearance
            let textSize: String
            let reduceMotion: Bool
        }
        let source: Source
        let selectedAt: Date
        let title: String
        let context: String
        let captureConditions: Conditions?
        let document: PDFSelection?
    }

    /// The existing PDFSelection wire object, not PDF bytes or a new document/reading-state owner.
    struct PDFSelection: Codable, Equatable, Sendable {
        struct Region: Codable, Equatable, Sendable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double

            var isValid: Bool {
                x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
            }
        }
        struct TextRange: Codable, Equatable, Sendable {
            let location: Int
            let length: Int
        }
        struct Page: Codable, Equatable, Sendable {
            let occurrence: String
            let number: Int
            /// Crop-local top-left points, y down, rotation ignored.
            let regions: [Region]
            /// Page-local UTF-16 units at this exact source revision.
            let ranges: [TextRange]
        }
        let revision: String
        let blob: String
        let pages: [Page]
        let quote: String?

        /// Match the source's locator validation without inventing original page geometry.
        func validate() throws {
            guard !blob.isEmpty, revision.utf8.count == 64,
                  revision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  !pages.isEmpty else { throw AkylDocument.Failure.document }
            var occurrences: Set<String> = []
            var numbers: Set<Int> = []
            for page in pages {
                guard !page.occurrence.isEmpty, page.number > 0,
                      occurrences.insert(page.occurrence).inserted, numbers.insert(page.number).inserted,
                      page.regions.allSatisfy({ $0.isValid && $0.x >= 0 && $0.y >= 0
                          && ($0.x + $0.width).isFinite && ($0.y + $0.height).isFinite }),
                      page.ranges.allSatisfy({ $0.location >= 0 && $0.length > 0 && $0.location <= Int.max - $0.length })
                else { throw AkylDocument.Failure.document }
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, token, task, taskTitle, terminalPlace, frozenContext }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(AkylDocument.Version.self, forKey: .version)
        token = try values.decode(String.self, forKey: .token)
        guard UUID(uuidString: token) != nil else { throw AkylDocument.Failure.token }
        task = try values.decode(String.self, forKey: .task)
        taskTitle = try values.decode(String.self, forKey: .taskTitle)
        terminalPlace = try values.decode(TerminalPlace.self, forKey: .terminalPlace)
        guard !task.isEmpty, !terminalPlace.host.isEmpty, !terminalPlace.session.isEmpty else { throw AkylDocument.Failure.target }
        frozenContext = try values.decodeIfPresent(EvidenceSelection.self, forKey: .frozenContext)
        try validateDocument()
    }

    func encode(to encoder: Encoder) throws {
        try validateDocument()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(token, forKey: .token)
        try values.encode(task, forKey: .task)
        try values.encode(taskTitle, forKey: .taskTitle)
        try values.encode(terminalPlace, forKey: .terminalPlace)
        try values.encodeIfPresent(frozenContext, forKey: .frozenContext)
    }

    private func validateDocument() throws {
        guard let document = frozenContext?.document else { return }
        guard version == .v2 else { throw AkylDocument.Failure.version }
        try document.validate()
    }
}

enum AkylTaskReturn: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        let text: String
        let host: String
        let session: String
        let capturedAt: Date
    }
    case back(version: AkylDocument.Version, token: String)
    case selection(version: AkylDocument.Version, token: String, Selection)

    var version: AkylDocument.Version {
        switch self { case .back(let version, _), .selection(let version, _, _): version }
    }

    var token: String {
        switch self { case .back(_, let token), .selection(_, let token, _): token }
    }

    var selected: Selection? {
        switch self { case .back: nil; case .selection(_, _, let selected): selected }
    }

    static func capturing(_ text: String?, context: AkylTaskContext, host: String, session: String, at: Date) -> Self {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .back(version: context.version, token: context.token)
        }
        return .selection(version: context.version, token: context.token, Selection(text: text, host: host, session: session, capturedAt: at))
    }

    private enum CodingKeys: String, CodingKey { case version, token, selectedText, host, session, capturedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(AkylDocument.Version.self, forKey: .version)
        let token = try values.decode(String.self, forKey: .token)
        guard UUID(uuidString: token) != nil else { throw AkylDocument.Failure.token }
        let selectionKeys: [CodingKeys] = [.selectedText, .host, .session, .capturedAt]
        let present = selectionKeys.filter { values.contains($0) }
        if present.isEmpty { self = .back(version: version, token: token); return }
        guard present.count == selectionKeys.count else { throw AkylDocument.Failure.selection }
        let text = try values.decode(String.self, forKey: .selectedText)
        let host = try values.decode(String.self, forKey: .host)
        let session = try values.decode(String.self, forKey: .session)
        guard !host.isEmpty, !session.isEmpty else { throw AkylDocument.Failure.selection }
        let at = try values.decode(Date.self, forKey: .capturedAt)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .back(version: version, token: token)
        } else {
            self = .selection(version: version, token: token, Selection(text: text, host: host, session: session, capturedAt: at))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(token, forKey: .token)
        if let selected {
            try values.encode(selected.text, forKey: .selectedText)
            try values.encode(selected.host, forKey: .host)
            try values.encode(selected.session, forKey: .session)
            try values.encode(selected.capturedAt, forKey: .capturedAt)
        }
    }
}

/// A disposable navigation bookmark in Lhûn's existing defaults, not another task/draft authority.
struct AkylVisit: Codable, Equatable, Sendable {
    struct Navigation: Codable, Equatable, Sendable {
        let host: String
        let panes: [String]
        let selection: String?
        let stacked: Bool
        let zoomed: String?
        let shares: [String: Double]
        var workspaceID: UUID? = nil
        var root: String? = nil
        var layout: CardTree? = nil
        var floating: [FloatingCard]? = nil
    }
    let context: AkylTaskContext
    var previous: Navigation
    var opened = false
    var pending: AkylTaskReturn?
    var recipient: String?
    var deliveryNote: String?

    /// A pending excerpt is only discarded by a separate explicit user action, never a new callback.
    mutating func stage(_ returned: AkylTaskReturn) -> Bool {
        guard returned.token == context.token, returned.version == context.version else { return false }
        if let pending, pending.selected != nil, pending != returned { return false }
        pending = returned
        recipient = nil
        deliveryNote = nil
        return true
    }
}
