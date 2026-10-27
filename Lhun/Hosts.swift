import Foundation

struct Host: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let phrase: String
    let address: String
    let user: String
    let hostKeys: [String]
    let port: Int

    struct Place {
        let id: String
        let name: String
        let phrase: String
    }

    static let mac = Place(id: "mac", name: "Mac", phrase: "the Mac")
    static let server = Place(id: "server", name: "Server", phrase: "the server")
    static let builtIn = [mac, server]

    static var all: [Host] {
        let paired = PairedHosts.stored
        return builtIn.compactMap { place in
            guard let machine = paired[place.id] else { return nil }
            return Host(
                id: place.id, name: place.name, phrase: place.phrase,
                address: machine.address, user: machine.user, hostKeys: machine.hostKeys,
                port: machine.port ?? 22
            )
        }
    }

    static var codeURL: URL? { PairedHosts.stored[mac.id]?.codeURL }
}

/// The machines paired in the hosts' places, by host id, kept with the app's settings.
enum PairedHosts {
    private static let key = "pairedHosts"

    static var stored: [String: PairedHost] {
        LhunDefaults.shared.data(forKey: key).flatMap { try? JSONDecoder().decode([String: PairedHost].self, from: $0) } ?? [:]
    }

    static func keep(_ host: PairedHost) throws {
        var all = stored
        all[host.id] = host
        LhunDefaults.shared.set(try JSONEncoder().encode(all), forKey: key)
    }
}
