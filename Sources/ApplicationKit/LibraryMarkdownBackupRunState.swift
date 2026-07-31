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
    var pendingSourceCursor: LibraryMarkdownBackupSourceCursor?
    var pendingJournalCompletion: PendingBackupJournalCompletion?
    var pendingRecoveryCheckpoint: LibraryMarkdownBackupSourceCursor?
    var pendingTermination: PendingLibraryMarkdownBackupTermination?
    var recoveryCursorCanAdvance = true

    var totalMeetings: Int { source.totalMeetings }
}

struct PendingBackupJournalCompletion: Sendable {
    let publication: LibraryMarkdownBackupRecoveryPublication
    let sourceCursor: LibraryMarkdownBackupSourceCursor
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
