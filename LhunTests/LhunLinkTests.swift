import Foundation
import Testing
@testable import LhunKit

@Test("An open link names its host and session, the name decoded as tools/alerts/lhun-alert encodes it", arguments: [
    ("lhun://open?host=mac&session=lhun-test-alerts-a", "mac", "lhun-test-alerts-a"),
    ("lhun://open?host=server&session=build%20logs", "server", "build logs"),
    ("lhun://open?session=a%20%26%20b%2Bc&host=mac", "mac", "a & b+c"),
    ("lhun://open?host=mac&session=x+y", "mac", "x+y"),
    ("lhun://open?host=mac&session=caf%C3%A9", "mac", "café"),
])
func linkNamesSession(link: String, host: String, name: String) throws {
    let url = try #require(URL(string: link))
    #expect(LhunLink.session(in: url) == SessionRef(host: host, name: name))
}

@Test("Any other link, or an open link missing its host or session, opens nothing", arguments: [
    "lhun://open?host=mac",
    "lhun://open?session=a",
    "lhun://open?host=&session=a",
    "lhun://open?host=mac&session=",
    "lhun://close?host=mac&session=a",
    "https://open?host=mac&session=a",
])
func linkOpensNothing(link: String) throws {
    let url = try #require(URL(string: link))
    #expect(LhunLink.session(in: url) == nil)
}

@Test("A web link opens only as it reads", arguments: [
    ("https://example.com/path?q=1#top", false),
    ("http://localhost:3000", false),
    ("https://münchen.de/straße", false),
    ("https://example.com/a%20b", false),
    ("https://example.com/\u{2028}evil.example", true),
    ("https://example.com/\u{2029}", true),
    ("https://example.com\u{202E}moc.live", true),
    ("https://exa\u{200B}mple.com", true),
    ("https://example.com/\u{7}", true),
    ("https://example.com/\nhttps://evil.example", true),
    ("https://example.com/\u{1B}[2J", true),
])
func webLinkHidesCharacters(link: String, hides: Bool) {
    #expect(URL.hidesCharacters(link) == hides)
}
