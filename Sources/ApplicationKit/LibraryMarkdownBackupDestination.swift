import Foundation

/// Opaque destination identity created only after backup admission. The
/// application adapter decides whether this is a regular or security-scoped
/// bookmark; ApplicationKit never interprets its bytes.
public struct LibraryMarkdownBackupDestinationBookmark:
    Codable,
    Equatable,
    Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// One bounded access interval for a resolved destination. Implementations
/// must make `close()` idempotent and balance any successful security-scope
/// acquisition there.
public protocol LibraryMarkdownBackupDestinationLease: AnyObject, Sendable {
    var directory: URL { get }
    var bookmark: LibraryMarkdownBackupDestinationBookmark { get }
    func close()
}

/// Converts the user's selected directory into durable identity and resolves
/// it only while one execution increment needs filesystem access.
public protocol LibraryMarkdownBackupDestinationAccess: Sendable {
    func prepare(
        directory: URL
    ) async throws -> LibraryMarkdownBackupDestinationBookmark

    func acquire(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease
}
