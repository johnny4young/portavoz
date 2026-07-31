import Foundation

struct PreparedLibraryMarkdownBackupSource: Sendable {
    let directory: URL
    let source: any LibraryMarkdownBackupSourceSession
}

struct ActiveLibraryMarkdownBackupRun: Sendable {
    let directory: URL
    var destinationBookmark: LibraryMarkdownBackupDestinationBookmark
    let source: any LibraryMarkdownBackupSourceSession
    var allocator: BackupFileNameAllocator
    var recoveryState: LibraryMarkdownBackupRecoveryState
    var exportedFileNames: [String] = []
    var failures: [LibraryMarkdownBackupFailure] = []
    var pending: PendingLibraryMarkdownBackupDocument?
    var pendingJournalCompletion: LibraryMarkdownBackupRecoveryPublication?
    var pendingTermination: PendingLibraryMarkdownBackupTermination?

    var totalMeetings: Int { source.totalMeetings }
}

enum PendingLibraryMarkdownBackupDocument: Sendable {
    case content(LibraryMarkdownBackupContent)
    case document(LibraryMarkdownBackupContent, Data)
    case publicationFailure(LibraryMarkdownBackupContent)
}

enum PendingLibraryMarkdownBackupTermination: Equatable, Sendable {
    case completed
    case sourceFailure
}

struct BackupRecoveryPersistenceError: Error {}
