import PortavozCore

/// Shared application boundary for user-managed credentials. Keychain calls
/// can wait on securityd, so presentation always enters through async methods
/// and never performs the synchronous platform operation on MainActor.
public struct ManageSecrets: Sendable {
    private let storage: any SecretStoring

    public init(storage: any SecretStoring) {
        self.storage = storage
    }

    public func value(for identifier: SecretIdentifier) async throws -> String? {
        let storage = storage
        return try await Task.detached(priority: .utility) {
            try storage.value(for: identifier)
        }.value
    }

    public func contains(_ identifier: SecretIdentifier) async throws -> Bool {
        try await value(for: identifier) != nil
    }

    public func set(_ secret: String, for identifier: SecretIdentifier) async throws {
        let storage = storage
        try await Task.detached(priority: .utility) {
            try storage.set(secret, for: identifier)
        }.value
    }

    public func delete(_ identifier: SecretIdentifier) async throws {
        let storage = storage
        try await Task.detached(priority: .utility) {
            try storage.delete(identifier)
        }.value
    }
}
