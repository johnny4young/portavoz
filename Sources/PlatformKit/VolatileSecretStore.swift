import Foundation
import PortavozCore

/// Process-local secret storage for disposable automation compositions.
///
/// Values never reach Keychain, disk, UserDefaults, logs, or another process.
/// Production composition continues to use `KeychainSecretStore`.
public final class VolatileSecretStore:
    SecretStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretIdentifier: String] = [:]

    public init() {}

    public func set(
        _ secret: String,
        for identifier: SecretIdentifier
    ) throws {
        lock.withLock {
            values[identifier] = secret
        }
    }

    public func value(
        for identifier: SecretIdentifier
    ) throws -> String? {
        lock.withLock {
            values[identifier]
        }
    }

    public func delete(
        _ identifier: SecretIdentifier
    ) throws {
        lock.withLock {
            _ = values.removeValue(forKey: identifier)
        }
    }
}
