import Foundation

/// External Markdown rendering remains behind an app adapter so
/// IntegrationsKit never leaks into Settings presentation.
public protocol LibraryMarkdownBackupDocuments: Sendable {
    func markdownDocument(
        for content: LibraryMarkdownBackupContent
    ) async throws -> Data
}

public enum LibraryMarkdownBackupPublication: Equatable, Sendable {
    case published
    case nameCollision
}

/// Exact destination evidence for one previously reserved publication.
public enum BackupPublicationEvidence: Equatable, Sendable {
    case missing
    case matching
    case conflicting
}

/// Filesystem capability. Publication uses a same-directory atomic move,
/// never replaces a destination, and inspects only one exact reserved name.
public protocol LibraryMarkdownBackupFiles: Sendable {
    func existingMarkdownFileNames(
        in directory: URL
    ) async throws -> Set<String>
    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) async throws -> LibraryMarkdownBackupPublication
    func evidence(
        for publication: LibraryMarkdownBackupRecoveryPublication,
        in directory: URL
    ) async throws -> BackupPublicationEvidence
}
