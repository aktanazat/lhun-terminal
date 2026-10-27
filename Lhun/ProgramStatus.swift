import Foundation

/// What a program in a pane says about itself through the program status protocol (OSC 7501, Mitchell
/// Hashimoto's): it works, waits on him, has finished, has failed, or sits idle. tmux drops those
/// reports, so each host's lhun-tap reads them from the panes' output (tools/status) and publishes one
/// atomic summary and record snapshot in the pane's `@lhun-status` option. A pane with a status goes by
/// it; the title and bell guesses are for the programs that never report.
struct ProgramStatus: Equatable, Sendable {
    /// In order of urgency, the least first.
    enum State: String, Comparable, Sendable {
        case idle
        case done
        case working
        case error
        /// It waits on him.
        case blocked

        static func < (a: State, b: State) -> Bool {
            a.urgency < b.urgency
        }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .done: "Done"
            case .working: "Working"
            case .error: "Failed"
            case .blocked: "Needs You"
            }
        }

        private var urgency: Int {
            switch self {
            case .idle: 0
            case .done: 1
            case .working: 2
            case .error: 3
            case .blocked: 4
            }
        }
    }

    /// What a blocked program waits for.
    enum Kind: String, Sendable {
        case permission
        case question
        case auth

        var label: String {
            switch self {
            case .permission: "Approval"
            case .question: "Question"
            case .auth: "Sign-in"
            }
        }
    }

    struct Record: Identifiable, Equatable, Sendable {
        let id: String
        let state: State
        let kind: Kind?
        let progress: Int?
        let app: String?
        let title: String?
        let message: String?
        let seq: String?

        fileprivate init?(pairs: [Substring: Substring]) {
            guard let id = pairs["id"], Self.validID(id),
                  let state = pairs["state"].flatMap({ State(rawValue: String($0)) }) else { return nil }
            self.id = String(id)
            self.state = state
            kind = state == .blocked ? pairs["kind"].flatMap { Kind(rawValue: String($0)) } : nil
            progress = state == .working || state == .blocked
                ? pairs["progress"].flatMap { Int($0) }.flatMap { (0...100).contains($0) ? $0 : nil }
                : nil
            app = pairs["app"].map { ProgramStatus.disarmed(String($0)) }.flatMap { $0.isEmpty ? nil : $0 }
            title = pairs["title"].flatMap(ProgramStatus.decoded)
            message = pairs["msg"].flatMap(ProgramStatus.decoded)
            seq = pairs["seq"].map(String.init)
        }

        private static func validID(_ id: Substring) -> Bool {
            guard !id.isEmpty else { return true }
            guard id.utf8.count <= 128 else { return false }
            let segments = id.split(separator: "/", omittingEmptySubsequences: false)
            return segments.count <= 8 && segments.allSatisfy { segment in
                !segment.isEmpty && segment.utf8.count <= 32 && segment.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                        || byte == 95 || byte == 46 || byte == 43 || byte == 45
                }
            }
        }
    }

    /// nil once something in the pane has reported but no record is left: its programs have ended.
    let state: State?
    let kind: Kind?
    /// Percent done, 0 to 100.
    let progress: Int?
    /// The program by its own name, such as "omp".
    let app: String?
    let title: String?
    /// What it says, as one line he can trust: see `disarmed`.
    let message: String?
    /// How many records the pane's programs hold.
    let records: Int
    /// Set for a done or an error, and new with each one, so a finish he has seen stays seen.
    let seq: String?
    let items: [Record]?
    let itemsUnavailable: Bool

    /// Reads the tap's summary, the protocol's own pairs:
    /// `state=…[:kind=…][:progress=…][:app=…][:title=…][:msg=…]:records=…[:seq=…]`, title and msg in
    /// base64; just `records=0` once no record is left. New taps append `:items=<base64>` with complete
    /// newline-separated records, or `:items=unavailable` when they exceed the transport limit.
    /// Empty, nothing in the pane has reported. Any program in a tmux pane can set the option, so a
    /// summary that does not read counts as none; invalid record details leave its summary intact.
    init?(summary: String) {
        guard let pairs = Self.pairs(summary) else { return nil }
        guard let records = pairs["records"].flatMap({ Int($0) }), records >= 0 else { return nil }
        if let state = pairs["state"] {
            guard let known = State(rawValue: String(state)) else { return nil }
            self.state = known
        } else {
            guard records == 0 else { return nil }
            state = nil
        }
        self.records = records
        kind = pairs["kind"].flatMap { Kind(rawValue: String($0)) }
        progress = pairs["progress"].flatMap { Int($0) }.flatMap { (0...100).contains($0) ? $0 : nil }
        app = pairs["app"].map { Self.disarmed(String($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        title = pairs["title"].flatMap(Self.decoded)
        message = pairs["msg"].flatMap(Self.decoded)
        seq = pairs["seq"].map(String.init)
        if let encoded = pairs["items"] {
            items = Self.readItems(encoded, count: records)
            itemsUnavailable = items == nil
        } else {
            items = nil
            itemsUnavailable = false
        }
    }

    private static func pairs(_ text: String) -> [Substring: Substring]? {
        var pairs: [Substring: Substring] = [:]
        for pair in text.split(separator: ":") {
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            pairs[pair[..<equals]] = pair[pair.index(after: equals)...]
        }
        return pairs
    }

    private static func readItems(_ encoded: Substring, count: Int) -> [Record]? {
        guard encoded != "unavailable", (1...256).contains(count), encoded.utf8.count <= 10_924,
              let data = Data(base64Encoded: String(encoded)), data.count < 8192,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var items: [Record] = []
        items.reserveCapacity(count)
        var ids: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard items.count < count, let pairs = Self.pairs(String(line)),
                  let item = Record(pairs: pairs), ids.insert(item.id).inserted else { return nil }
            items.append(item)
        }
        guard items.count == count else { return nil }
        items.sort { $0.state != $1.state ? $0.state > $1.state : $0.id < $1.id }
        return items
    }

    private static func decoded(_ base64: Substring) -> String? {
        guard let data = Data(base64Encoded: String(base64)), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = disarmed(text)
        return line.isEmpty ? nil : line
    }

    /// One line, without what could make it read as something other than it is: control characters
    /// and line breaks become spaces, and invisible formatting goes, bidirectional overrides and
    /// isolates among it. The joiners stay, since emoji are built with them.
    static func disarmed(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                line.append(" ")
            case .format:
                if scalar == "\u{200D}" || scalar == "\u{200C}" { line.append(scalar) }
            default:
                line.append(scalar)
            }
        }
        return String(line).trimmingCharacters(in: .whitespaces)
    }
}
