import Foundation
import PortavozCore

/// Deterministic secret adapter for capability and application tests. The
/// concrete Keychain adapter keeps one focused integration test of its own.
final class TestSecretStorage: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretIdentifier: String] = [:]

    func set(_ secret: String, for identifier: SecretIdentifier) throws {
        lock.withLock { values[identifier] = secret }
    }

    func value(for identifier: SecretIdentifier) throws -> String? {
        lock.withLock { values[identifier] }
    }

    func delete(_ identifier: SecretIdentifier) throws {
        lock.withLock { _ = values.removeValue(forKey: identifier) }
    }
}
