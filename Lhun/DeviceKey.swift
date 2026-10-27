import CryptoKit
import Foundation
import NIOSSH
import OSLog
import Security
import UIKit

/// This device's SSH identity: a P-256 key made inside the Secure Enclave.
///
/// The private half never leaves the chip. The Keychain holds only the enclave's wrapped handle to it,
/// readable after the first unlock and never synced or restored to another device. Signing needs no
/// Face ID, so reconnects stay silent.
struct DeviceKey: Sendable {
    let privateKey: NIOSSHPrivateKey
    /// The public half as one `authorized_keys` line.
    let publicKeyLine: String

    enum Failure: LocalizedError {
        case noSecureEnclave
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noSecureEnclave: "This device has no Secure Enclave, so Lhûn cannot make a key."
            case .keychain(let status): "The Keychain refused the key (\(status))."
            }
        }
    }

    private static let service = "com.aktanazat.lhun"
    private static let account = "device-key"
    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "key")

    @MainActor
    static func loadOrCreate() throws -> DeviceKey {
        guard SecureEnclave.isAvailable else { throw Failure.noSecureEnclave }
        let enclaveKey = try stored() ?? create()
        let key = NIOSSHPrivateKey(secureEnclaveP256Key: enclaveKey)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let line = String(openSSHPublicKey: key.publicKey) + " lhun-\(device)"
        writePublicKeyFile(line)
        return DeviceKey(privateKey: key, publicKeyLine: line)
    }

    private static func stored() throws -> SecureEnclave.P256.Signing.PrivateKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let handle = item as? Data else { throw Failure.keychain(status) }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle)
    }

    private static func create() throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: key.dataRepresentation,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }

    /// Leaves the public key in the app's Documents folder as `lhun.pub`, where `devicectl` can copy it
    /// off the device for setup. It is public, so nothing is lost if it is read.
    private static func writePublicKeyFile(_ line: String) {
        let url = URL.documentsDirectory.appending(path: "lhun.pub")
        do {
            try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("Could not write lhun.pub: \(error.localizedDescription, privacy: .public)")
        }
    }
}
