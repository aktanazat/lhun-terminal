#if targetEnvironment(simulator)
import CryptoKit
import Foundation
import NIOSSH

extension DeviceKey {
    enum SimulatorFailure: LocalizedError {
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unwritable(let path): "Lhûn could not save the simulator's key at \(path)."
            }
        }
    }

    @MainActor
    static func simulator() throws -> DeviceKey {
        let folder = URL.applicationSupportDirectory.appending(path: "simulator")
        let file = folder.appending(path: "key")
        let files = FileManager.default
        let softwareKey: P256.Signing.PrivateKey
        if files.fileExists(atPath: file.path(percentEncoded: false)) {
            softwareKey = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: file, encoding: .utf8))
        } else {
            softwareKey = P256.Signing.PrivateKey()
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard files.createFile(
                atPath: file.path(percentEncoded: false),
                contents: Data(softwareKey.pemRepresentation.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SimulatorFailure.unwritable(file.path(percentEncoded: false))
            }
        }
        let key = NIOSSHPrivateKey(p256Key: softwareKey)
        let line = String(openSSHPublicKey: key.publicKey) + " lhun-simulator"
        try (line + "\n").write(to: folder.appending(path: "key.pub"), atomically: true, encoding: .utf8)
        return DeviceKey(privateKey: key, publicKeyLine: line)
    }
}
#endif
