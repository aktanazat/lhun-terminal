import Foundation

/// Addresses a program on the host prints for itself: `http://localhost:5173/`, `127.0.0.1:8000`,
/// `http://0.0.0.0:3000`, `http://[::]:8765/`. On the host they all mean "this machine", so on this
/// device they open in the preview, through a tunnel, instead of in Safari, where they would mean the
/// iPad itself.
enum LocalURL {
    /// The host's port a link points at, when the link points at the host itself.
    static func port(of url: URL) -> Int? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), isLocal(host) else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return (1...65535).contains(port) ? port : nil
    }

    /// The ports of every local address in `text`, in the order they first appear. A bare host only
    /// counts with a port after it, and a port only with a scheme or a host before it, so prose that
    /// mentions localhost or a number is left alone.
    static func ports(in text: String) -> [Int] {
        var ports: [Int] = []
        for match in text.matches(of: pattern) {
            guard startsCleanly(match.range.lowerBound, in: text) else { continue }
            let port: Int
            if let digits = match.output.port {
                guard let number = Int(digits), (1...65535).contains(number),
                      endsCleanly(match.range.upperBound, in: text, afterPort: true) else { continue }
                port = number
            } else {
                guard let scheme = match.output.scheme, endsCleanly(match.range.upperBound, in: text, afterPort: false) else { continue }
                port = scheme.lowercased().hasPrefix("https") ? 443 : 80
            }
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    /// Built on each use: `Regex` is not `Sendable`, so it can't be shared as a stored constant.
    private static var pattern: Regex<(Substring, scheme: Substring?, port: Substring?)> {
        /(?<scheme>https?:\/\/)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::(?<port>\d{1,5}))?/.ignoresCase()
    }

    private static func isLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "::"].contains(bare)
    }

    /// Whether a match starts at the start of a word: `notlocalhost:3000` and `user@localhost:22` are
    /// not addresses to preview.
    private static func startsCleanly(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !(before.isLetter || before.isNumber || "@.-_/:".contains(before))
    }

    /// Whether a match ends where the address does: `localhost:123456` and `localhost.example.com`
    /// are something else.
    private static func endsCleanly(_ index: String.Index, in text: String, afterPort: Bool) -> Bool {
        guard index < text.endIndex else { return true }
        let after = text[index]
        if after.isNumber { return false }
        if afterPort { return true }
        if after.isLetter || "-_".contains(after) { return false }
        let next = text.index(after: index)
        return !(after == "." && next < text.endIndex && (text[next].isLetter || text[next].isNumber))
    }
}
