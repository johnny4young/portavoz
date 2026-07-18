import Foundation
import PortavozCore
import Security

/// Device-only Keychain adapter. API keys and encryption keys never live in
/// SQLite, UserDefaults, iCloud Keychain backups, sync payloads, or logs.
public struct KeychainSecretStore: SecretStoring, Sendable {
    private static let account = "portavoz"

    public enum SecretError: Error, LocalizedError {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            }
        }
    }

    public init() {}

    public func set(_ secret: String, for identifier: SecretIdentifier) throws {
        try? delete(identifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    public func value(for identifier: SecretIdentifier) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            // Keychain writes UTF-8 above, so decoding is total by contract.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretError.keychain(status)
        }
    }

    public func delete(_ identifier: SecretIdentifier) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.keychain(status)
        }
    }
}
