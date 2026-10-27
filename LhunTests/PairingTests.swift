import Foundation
import Testing
@testable import LhunKit

private let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFEbfJMrar8DHBcEBH0Zb1e57jYTyiXKBRIM+rNBADf4"
private let ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBLDfQb2zhirZNWTqvoGnHWIu7w8SA90pc0WMsjuKCi1L6UCVEpoyN4fm2hXmjQyQ0H+0nBO5Y4ySzSB1oq1lcA="
private let encodedEd25519 = "ssh-ed25519%20AAAAC3NzaC1lZDI1NTE5AAAAIFEbfJMrar8DHBcEBH0Zb1e57jYTyiXKBRIM%2BrNBADf4"

@Test("A percent-encoded pairing link keeps the machine, account and complete host keys")
func pairingLinkNamesMachine() throws {
    let link = "lhun://pair?role=mac&name=%64%65%76%65%6c%6f%70%65%72%e2%80%99%73%20%4d%61%63&address=%31%39%32%2e%30%2e%32%2e%31"
        + "&user=%64%65%76%65%6c%6f%70%65%72&key=\(encodedEd25519)"
        + "&key=ecdsa-sha2-nistp256%20AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBLDfQb2zhirZNWTqvoGnHWIu7w8SA90pc0WMsjuKCi1L6UCVEpoyN4fm2hXmjQyQ0H%2B0nBO5Y4ySzSB1oq1lcA%3D"
    let url = try #require(URL(string: link))
    let paired = try #require(Pairing.host(in: url))
    #expect(paired == PairedHost(id: "mac", machine: "developer’s Mac", address: "192.0.2.1", user: "developer", hostKeys: [ed25519, ecdsa], port: nil, codeURL: nil))
}

@Test("A pairing link inside pasted text is found")
func pairingLinkInText() {
    let text = "copied:\n  lhun://pair?role=server&address=192.0.2.2&user=developer&key=\(encodedEd25519)\n"
    #expect(Pairing.host(inText: text)?.address == "192.0.2.2")
}

@Test("A malformed role, shell-like address/account or unsupported host key pairs nothing", arguments: [
    "lhun://pair?role=laptop&address=192.0.2.1&user=a&key=\(encodedEd25519)",
    "lhun://pair?role=mac&address=192.0.2.1%3Brm&user=a&key=\(encodedEd25519)",
    "lhun://pair?role=mac&address=192.0.2.1&user=a%20b&key=\(encodedEd25519)",
    "lhun://pair?role=mac&user=a&key=\(encodedEd25519)",
    "lhun://pair?role=mac&address=192.0.2.1&key=\(encodedEd25519)",
    "lhun://pair?role=mac&address=192.0.2.1&user=a",
    "lhun://pair?role=mac&address=192.0.2.1&user=a&key=ssh-rsa%20AAAAB3NzaC1yc2E",
    "lhun://pair?role=mac&address=192.0.2.1&user=a&key=\(encodedEd25519)&key=ssh-ed25519%20not*base64",
    "https://pair?role=mac&address=192.0.2.1&user=a&key=\(encodedEd25519)",
])
func linkPairsNothing(link: String) throws {
    let url = try #require(URL(string: link))
    #expect(Pairing.host(in: url) == nil)
}

@Test("A pairing can name a nonstandard SSH port and a separate browser editor")
func pairingWithPortAndEditor() throws {
    let url = try #require(URL(string: "lhun://pair?role=mac&address=192.0.2.1&user=developer&key=\(encodedEd25519)&port=22222&code=https%3A%2F%2Feditor.example.invalid%3A8443"))
    let paired = try #require(Pairing.host(in: url))
    #expect(paired.port == 22222)
    #expect(paired.codeURL == URL(string: "https://editor.example.invalid:8443"))
}

@Test("Invalid ports and non-web or credential-bearing editor URLs are rejected", arguments: [
    "port=0", "port=-1", "port=65536", "port=ssh",
    "code=file%3A%2F%2F%2Fetc%2Fhosts", "code=https%3A%2F%2Fuser%3Apassword%40editor.example.invalid",
])
func pairingRejectsInvalidEndpointOptions(option: String) throws {
    let url = try #require(URL(string: "lhun://pair?role=mac&address=192.0.2.1&user=developer&key=\(encodedEd25519)&\(option)"))
    #expect(Pairing.host(in: url) == nil)
}

@Test("Previously stored pairings still decode without the new endpoint options")
func pairingStoredBeforeEndpointOptions() throws {
    let data = Data("""
    {"id":"mac","machine":"Example Mac","address":"192.0.2.1","user":"developer","hostKeys":["\(ed25519)"]}
    """.utf8)
    let paired = try JSONDecoder().decode(PairedHost.self, from: data)
    #expect(paired == PairedHost(id: "mac", machine: "Example Mac", address: "192.0.2.1", user: "developer", hostKeys: [ed25519], port: nil, codeURL: nil))
}
