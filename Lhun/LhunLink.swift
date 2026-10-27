import Foundation

/// The links Lhûn opens. `lhun://open?host=mac&session=<name>` opens a session: each notification the
/// hosts' alert hook sends carries one (tools/alerts), so tapping it lands on the session that rang.
enum LhunLink {
    /// Whether the link is one of Lhûn's, whatever it asks for.
    static func isLhun(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "lhun"
    }

    /// The session an open link names, or nil for any other link or one missing either part. The name
    /// arrives percent-decoded, and a "+" in it stays a "+", since a tmux name may hold one.
    static func session(in url: URL) -> SessionRef? {
        guard isLhun(url), url.host() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let name = items.first(where: { $0.name == "session" })?.value, !name.isEmpty
        else { return nil }
        return SessionRef(host: host, name: name)
    }
}
