import Foundation

public struct BackupReconcileRequest: Sendable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public enum BackupReconcileBlock:
    Equatable,
    Sendable {
    case destinationConflict
    case missingSourceCursor
}

public enum BackupReconcileResult:
    Equatable,
    Sendable {
    case unavailable
    case noPending(LibraryMarkdownBackupRecoveryState)
    case retrySource(LibraryMarkdownBackupRecoveryState)
    case reconciled(LibraryMarkdownBackupRecoveryState)
    case blocked(
        LibraryMarkdownBackupRecoveryState,
        BackupReconcileBlock)
}

public enum BackupReconcileError:
    Error,
    Equatable,
    Sendable {
    case recoveryUnavailable
    case destinationUnavailable
}

/// Resolves only the durable reservation/destination crash window. Stage
/// adoption and continued rendering remain separate launch orchestration.
public struct ReconcileBackupPublication: ApplicationUseCase {
    private let files: any LibraryMarkdownBackupFiles
    private let destinationAccess: any LibraryMarkdownBackupDestinationAccess
    private let recoveryStore: any LibraryMarkdownBackupRecoveryStore

    public init(
        files: any LibraryMarkdownBackupFiles,
        destinationAccess: any LibraryMarkdownBackupDestinationAccess,
        recoveryStore: any LibraryMarkdownBackupRecoveryStore
    ) {
        self.files = files
        self.destinationAccess = destinationAccess
        self.recoveryStore = recoveryStore
    }

    public func execute(
        _ request: BackupReconcileRequest
    ) async throws -> BackupReconcileResult {
        try Task.checkCancellation()
        guard var state = try await load(operationID: request.operationID)
        else { return .unavailable }

        guard state.phase == .active else {
            return .noPending(state)
        }
        guard let pending = state.pendingPublication else {
            return try await repairCheckpointIfNeeded(state: &state)
                ? .reconciled(state)
                : .noPending(state)
        }

        let lease = try await acquireDestination(
            bookmark: state.destinationBookmark)
        defer { lease.close() }
        if lease.bookmark != state.destinationBookmark {
            try await apply(
                .updateDestinationBookmark(lease.bookmark),
                operationID: state.operationID)
            state.destinationBookmark = lease.bookmark
        }

        let evidence = try await destinationEvidence(
            for: pending,
            in: lease.directory)
        switch evidence {
        case .missing:
            try await apply(
                .clearReservation,
                operationID: state.operationID)
            state.pendingPublication = nil
            return .retrySource(state)
        case .conflicting:
            return .blocked(state, .destinationConflict)
        case .matching:
            guard pending.sourceCursor != nil else {
                return .blocked(state, .missingSourceCursor)
            }
            try await apply(
                .complete(pending),
                operationID: state.operationID)
            state.completedPublications.append(pending)
            state.pendingPublication = nil
            _ = try await repairCheckpointIfNeeded(state: &state)
            return .reconciled(state)
        }
    }
}

private extension ReconcileBackupPublication {
    func load(
        operationID: UUID
    ) async throws -> LibraryMarkdownBackupRecoveryState? {
        do {
            return try await recoveryStore.load(operationID: operationID)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackupReconcileError.recoveryUnavailable
        }
    }

    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) async throws {
        do {
            try await recoveryStore.apply(
                mutation,
                operationID: operationID)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackupReconcileError.recoveryUnavailable
        }
    }

    func acquireDestination(
        bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        do {
            return try await destinationAccess.acquire(bookmark: bookmark)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackupReconcileError.destinationUnavailable
        }
    }

    func destinationEvidence(
        for publication: LibraryMarkdownBackupRecoveryPublication,
        in directory: URL
    ) async throws -> BackupPublicationEvidence {
        do {
            return try await files.evidence(
                for: publication,
                in: directory)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackupReconcileError.destinationUnavailable
        }
    }

    func repairCheckpointIfNeeded(
        state: inout LibraryMarkdownBackupRecoveryState
    ) async throws -> Bool {
        let publicationCursors = state.completedPublications
            .compactMap(\.sourceCursor)
        let failureCursors = state.failures.map(\.sourceCursor)
        let cursors = publicationCursors + failureCursors
        guard var cursor = cursors.first else { return false }
        for candidate in cursors.dropFirst()
        where Self.isAfter(candidate, cursor) {
            cursor = candidate
        }
        if let current = state.sourceCursor,
           !Self.isAfter(cursor, current) {
            return false
        }
        try await apply(
            .checkpointSource(cursor),
            operationID: state.operationID)
        state.sourceCursor = cursor
        return true
    }

    static func isAfter(
        _ candidate: LibraryMarkdownBackupSourceCursor,
        _ current: LibraryMarkdownBackupSourceCursor
    ) -> Bool {
        candidate.startedAt < current.startedAt
            || (
                candidate.startedAt == current.startedAt
                    && candidate.recordID > current.recordID
            )
    }
}
