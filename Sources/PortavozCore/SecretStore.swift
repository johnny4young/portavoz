import Foundation
import Security

/// Keychain-backed secrets. API keys and tokens NEVER live in SQLite or
/// UserDefaults (D4/D8 — the anti-pattern we inherited from studying
/// Meetily, which keeps them in a plain settings table).
public enum SecretStore {
    public static let gitHubTokenService = "app.portavoz.github-token"
    static let account = "portavoz"

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

    public static func set(_ secret: String, service: String) throws {
        try? delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            // This-device-only, never in iCloud Keychain backups.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    public static func get(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretError.keychain(status)
        }
    }

    public static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.keychain(status)
        }
    }
}
