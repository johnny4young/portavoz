import Foundation
import PortavozCore
import Security

/// Device-only Keychain adapter. API keys and encryption keys never live in
/// SQLite, UserDefaults, iCloud Keychain backups, sync payloads, or logs.
public struct KeychainSecretStore: SecretStoring, Sendable {
    private static let account = "portavoz"
    private let security: SecurityClient

    /// Synchronous injected Security boundary. Tests use process-local values only.
    struct SecurityClient: Sendable {
        var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
        var add: @Sendable (CFDictionary) -> OSStatus
        var copyMatching: @Sendable (CFDictionary) -> (status: OSStatus, data: Data?)
        var delete: @Sendable (CFDictionary) -> OSStatus

        static let live = SecurityClient(
            update: { SecItemUpdate($0, $1) },
            add: { SecItemAdd($0, nil) },
            copyMatching: { query in
                var result: AnyObject?
                let status = SecItemCopyMatching(query, &result)
                return (status, result as? Data)
            },
            delete: { SecItemDelete($0) })
    }

    public enum SecretError: Error, LocalizedError {
        case keychain(OSStatus)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            case .invalidData:
                return "keychain value has an invalid encoding"
            }
        }
    }

    public init() {
        security = .live
    }

    init(security: SecurityClient) {
        self.security = security
    }

    public func set(_ secret: String, for identifier: SecretIdentifier) throws {
        let query = matchingQuery(for: identifier)
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        var status = security.update(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            guard status == errSecSuccess else { throw SecretError.keychain(status) }
            return
        }

        var addition = query
        addition[kSecValueData as String] = Data(secret.utf8)
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = security.add(addition as CFDictionary)
        if status == errSecDuplicateItem {
            // Another first writer won after our missing-item check. One atomic update
            // resolves that contender; there is no destructive delete or unbounded loop.
            status = security.update(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    private func matchingQuery(for identifier: SecretIdentifier) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account
        ]
    }

    public func value(for identifier: SecretIdentifier) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let result = security.copyMatching(query as CFDictionary)
        switch result.status {
        case errSecSuccess:
            // Reject malformed authority rather than returning a replacement-character value.
            // swiftlint:disable:next optional_data_string_conversion
            guard let data = result.data, let value = String(data: data, encoding: .utf8) else {
                throw SecretError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretError.keychain(result.status)
        }
    }

    public func delete(_ identifier: SecretIdentifier) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.rawValue,
            kSecAttrAccount as String: Self.account
        ]
        let status = security.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.keychain(status)
        }
    }
}
