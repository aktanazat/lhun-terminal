import Foundation

/// Filter or create: when what is typed matches no session and names none, the palette offers a new session
/// by that name. It goes at the foot of the sessions, so Return still runs a better match, and it is first
/// only when nothing else matched.
enum FilterOrCreate {
    /// The name typed, without the blanks around it; nil when that leaves nothing, when a session matched,
    /// or when a session already has the name.
    static func name(_ query: String, sessions: [String], sessionMatched: Bool) -> String? {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !sessionMatched, !sessions.contains(name) else { return nil }
        return name
    }
}
