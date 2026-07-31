import Foundation
import PortavozCore

/// Exports every healthy live meeting while preserving failures as typed,
/// content-free partial results. Existing files are never replaced. The actor
/// retains one staged run across capture-policy suspension.
public actor ExportLibraryMarkdownBackup: ApplicationUseCase {
    private static let workload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .mediaExport,
        operation: .execute)

    private let store: any LibraryMarkdownBackupStore
    private let documents: any LibraryMarkdownBackupDocuments
    private let files: any LibraryMarkdownBackupFiles
    private let destinationAccess: any LibraryMarkdownBackupDestinationAccess
    private let recoveryStore: any LibraryMarkdownBackupRecoveryStore
    private let maintenanceGate: DurableMaintenanceGate
    private var preparedSource: PreparedLibraryMarkdownBackupSource?
    private var activeRun: ActiveLibraryMarkdownBackupRun?
    private var isExecuting = false

    public init(
        store: any LibraryMarkdownBackupStore,
        documents: any LibraryMarkdownBackupDocuments,
        files: any LibraryMarkdownBackupFiles,
        destinationAccess: any LibraryMarkdownBackupDestinationAccess,
        recoveryStore: any LibraryMarkdownBackupRecoveryStore,
        maintenanceGate: DurableMaintenanceGate = .unrestricted
    ) {
        self.store = store
        self.documents = documents
        self.files = files
        self.destinationAccess = destinationAccess
        self.recoveryStore = recoveryStore
        self.maintenanceGate = maintenanceGate
    }

    public func execute(
        _ request: ExportLibraryMarkdownBackupRequest
    ) async throws -> LibraryMarkdownBackupExecution {
        guard !isExecuting else {
            throw LibraryMarkdownBackupError.operationInProgress
        }
        isExecuting = true
        defer { isExecuting = false }

        await request.progress(.preparing)
        if let termination = try await resumeTerminationIfNeeded(for: request) {
            return termination
        }
        let destinationLease: any LibraryMarkdownBackupDestinationLease
        if let activeRun {
            guard Self.sameDirectory(activeRun.directory, request.directory) else {
                throw LibraryMarkdownBackupError.operationInProgress
            }
            destinationLease = try await acquireDestination(
                activeRun.destinationBookmark)
        } else {
            guard let preparedLease = try await prepareRun(
                in: request.directory
            ) else {
                return .suspended
            }
            destinationLease = preparedLease
        }
        defer { destinationLease.close() }
        guard var run = activeRun,
              Self.sameDirectory(run.directory, request.directory)
        else {
            throw LibraryMarkdownBackupError.operationInProgress
        }
        do {
            try await refreshDestinationBookmark(
                destinationLease.bookmark,
                in: &run)
        } catch {
            activeRun = run
            throw LibraryMarkdownBackupError.libraryUnavailable
        }

        await publishProgress(
            total: run.totalMeetings,
            exported: run.exportedFileNames.count,
            failures: run.failures.count,
            through: request.progress)

        while shouldProceed(at: .checkpoint) {
            do {
                if let completion = try await advance(
                    run: &run,
                    directory: destinationLease.directory,
                    progress: request.progress
                ) {
                    return completion
                }
                activeRun = run
            } catch is BackupRecoveryPersistenceError {
                // A post-move journal failure must not rewind the process-local
                // run and publish the same document again on retry.
                activeRun = run
                throw LibraryMarkdownBackupError.libraryUnavailable
            }
        }
        activeRun = run
        return .suspended
    }

    /// Restores one already-reconciled immutable run. The caller must have
    /// adopted the exact source stage and cursor first. Setup failure releases
    /// that lease without deleting the stage so a later launch can retry.
    public func restoreRecoveredRun(
        source: any LibraryMarkdownBackupSourceSession,
        state recoveredState: LibraryMarkdownBackupRecoveryState
    ) async throws -> URL {
        guard !isExecuting,
              preparedSource == nil,
              activeRun == nil
        else {
            await source.abandon()
            throw LibraryMarkdownBackupError.operationInProgress
        }
        guard LibraryMarkdownBackupRecoveryValidation.isValid(
            recoveredState,
            for: source,
            phase: .active)
        else {
            await source.abandon()
            throw LibraryMarkdownBackupError.libraryUnavailable
        }

        var destinationLease: (any LibraryMarkdownBackupDestinationLease)?
        do {
            let lease = try await acquireDestination(
                recoveredState.destinationBookmark)
            destinationLease = lease
            var state = recoveredState
            if lease.bookmark != state.destinationBookmark {
                try await applyRecovery(
                    .updateDestinationBookmark(lease.bookmark),
                    operationID: state.operationID)
                state.destinationBookmark = lease.bookmark
            }
            let existing = try await existingFileNames(
                in: lease.directory)
                .union(state.completedPublications.map(\.fileName))
            activeRun = ActiveLibraryMarkdownBackupRun(
                directory: lease.directory,
                destinationBookmark: lease.bookmark,
                source: source,
                allocator: BackupFileNameAllocator(existing: existing),
                recoveryState: state,
                exportedFileNames: state.completedPublications.map(\.fileName),
                failures: state.failures.map(\.failure))
            destinationLease?.close()
            return lease.directory
        } catch {
            destinationLease?.close()
            await source.abandon()
            if let error = error as? LibraryMarkdownBackupError {
                throw error
            }
            if error is BackupRecoveryPersistenceError {
                throw LibraryMarkdownBackupError.libraryUnavailable
            }
            throw LibraryMarkdownBackupError.destinationUnavailable
        }
    }

    /// True while retrying this actor can continue an already-owned immutable
    /// source. Launch recovery uses this only to distinguish a retryable error
    /// from terminal cleanup that already removed the journal and stage.
    public func hasPendingRun() -> Bool {
        preparedSource != nil || activeRun != nil
    }
}

private extension ExportLibraryMarkdownBackup {
    func resumeTerminationIfNeeded(
        for request: ExportLibraryMarkdownBackupRequest
    ) async throws -> LibraryMarkdownBackupExecution? {
        guard var run = activeRun,
              run.pendingTermination != nil
        else { return nil }
        guard Self.sameDirectory(run.directory, request.directory) else {
            throw LibraryMarkdownBackupError.operationInProgress
        }
        do {
            return try await finishTermination(run: &run)
        } catch is BackupRecoveryPersistenceError {
            activeRun = run
            throw LibraryMarkdownBackupError.libraryUnavailable
        }
    }

    func shouldProceed(
        at phase: ResourceGovernorEvaluationPhase
    ) -> Bool {
        maintenanceGate.disposition(
            for: Self.workload,
            phase: phase) == .proceed
    }

    func advance(
        run: inout ActiveLibraryMarkdownBackupRun,
        directory: URL,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution? {
        if run.pendingRecoveryCheckpoint != nil {
            try await persistPendingRecoveryCheckpoint(
                in: &run,
                progress: progress)
            return nil
        }
        if let completion = run.pendingJournalCompletion {
            try await completeJournalPublication(
                completion,
                in: &run,
                progress: progress)
            return nil
        }
        switch run.pending {
        case nil:
            return try await loadNextEntry(
                into: &run,
                progress: progress)
        case .content(let content):
            try await render(
                content,
                into: &run,
                progress: progress)
            return nil
        case .document(let content, let data):
            try await publish(
                data,
                for: content,
                to: directory,
                into: &run,
                progress: progress)
            return nil
        case .sourceFailure(let failure):
            try await recordSourceFailure(
                failure,
                in: &run,
                progress: progress)
            return nil
        case .documentFailure(let content):
            try await recordDocumentFailure(
                for: content,
                in: &run,
                progress: progress)
            return nil
        case .publicationFailure(let content):
            try await recordPublicationFailure(
                for: content,
                in: &run,
                progress: progress)
            return nil
        }
    }

    func loadNextEntry(
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution? {
        let entry: LibraryMarkdownBackupSourceEntry?
        let sourceCursor: LibraryMarkdownBackupSourceCursor?
        do {
            entry = try await run.source.next()
            sourceCursor = if entry == nil {
                nil
            } else {
                try await run.source.checkpoint()
            }
        } catch {
            run.pendingTermination = .sourceFailure
            return try await finishTermination(run: &run)
        }
        guard let entry else {
            run.pendingTermination = .completed
            return try await finishTermination(run: &run)
        }
        guard let sourceCursor else {
            run.pendingTermination = .sourceFailure
            return try await finishTermination(run: &run)
        }
        run.pendingSourceCursor = sourceCursor
        switch entry {
        case .content(let content):
            run.pending = .content(content)
        case .failure(let failure):
            run.pending = .sourceFailure(failure)
        }
        return nil
    }

    func render(
        _ content: LibraryMarkdownBackupContent,
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        do {
            run.pending = .document(
                content,
                try await documents.markdownDocument(for: content))
        } catch {
            run.pending = .documentFailure(content)
            try await recordDocumentFailure(
                for: content,
                in: &run,
                progress: progress)
        }
    }

    func publish(
        _ data: Data,
        for content: LibraryMarkdownBackupContent,
        to directory: URL,
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        for _ in 0..<10_000 {
            let reservation = try await reserveNextPublication(
                data,
                for: content,
                in: &run)

            let publicationResult: LibraryMarkdownBackupPublication
            do {
                publicationResult = try await files.publishMarkdownDocument(
                    data,
                    named: reservation.fileName,
                    in: directory
                )
            } catch {
                run.pending = .publicationFailure(content)
                try await recordPublicationFailure(
                    for: content,
                    in: &run,
                    progress: progress)
                return
            }

            switch publicationResult {
            case .published:
                try await recordPublished(
                    reservation,
                    in: &run,
                    progress: progress)
                return
            case .nameCollision:
                continue
            }
        }

        run.pending = .publicationFailure(content)
        try await recordPublicationFailure(
            for: content,
            in: &run,
            progress: progress)
    }

    func prepareRun(
        in directory: URL
    ) async throws -> (any LibraryMarkdownBackupDestinationLease)? {
        guard try await prepareSourceIfNeeded(in: directory) else { return nil }
        guard shouldProceed(at: .checkpoint) else { return nil }
        guard let preparedSource else {
            preconditionFailure("prepared backup source must exist")
        }
        return try await activate(
            preparedSource,
            in: directory)
    }

    func prepareSourceIfNeeded(in directory: URL) async throws -> Bool {
        if let preparedSource {
            guard Self.sameDirectory(preparedSource.directory, directory) else {
                throw LibraryMarkdownBackupError.operationInProgress
            }
            return true
        }
        guard shouldProceed(at: .admission) else { return false }
        let gate = maintenanceGate
        let workload = Self.workload
        let preparation: LibraryMarkdownBackupSourcePreparation
        do {
            preparation = try await store.prepareLibraryMarkdownBackupSource {
                gate.disposition(
                    for: workload,
                    phase: .checkpoint) == .proceed
            }
        } catch {
            throw LibraryMarkdownBackupError.libraryUnavailable
        }
        guard case .ready(let source) = preparation else { return false }
        preparedSource = PreparedLibraryMarkdownBackupSource(
            directory: directory,
            source: source)
        return true
    }

    func activate(
        _ preparedSource: PreparedLibraryMarkdownBackupSource,
        in directory: URL
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        var destinationLease: (any LibraryMarkdownBackupDestinationLease)?
        do {
            let lease = try await acquireDestination(
                try await destinationAccess.prepare(directory: directory))
            destinationLease = lease
            let allocator = try await fileNameAllocator(
                in: lease.directory)
            let recoveryState = LibraryMarkdownBackupRecoveryState(
                operationID: preparedSource.source.id,
                destinationBookmark: lease.bookmark)
            try await applyRecovery(
                .begin(destinationBookmark: lease.bookmark),
                operationID: recoveryState.operationID)
            activeRun = ActiveLibraryMarkdownBackupRun(
                directory: preparedSource.directory,
                destinationBookmark: lease.bookmark,
                source: preparedSource.source,
                allocator: allocator,
                recoveryState: recoveryState)
            self.preparedSource = nil
            return lease
        } catch {
            destinationLease?.close()
            await preparedSource.source.close()
            self.preparedSource = nil
            if error is LibraryMarkdownBackupError {
                throw error
            }
            if error is BackupRecoveryPersistenceError {
                throw LibraryMarkdownBackupError.libraryUnavailable
            }
            throw LibraryMarkdownBackupError.destinationUnavailable
        }
    }

    func refreshDestinationBookmark(
        _ bookmark: LibraryMarkdownBackupDestinationBookmark,
        in run: inout ActiveLibraryMarkdownBackupRun
    ) async throws {
        guard run.destinationBookmark != bookmark else { return }
        try await applyRecovery(
            .updateDestinationBookmark(bookmark),
            operationID: run.recoveryState.operationID)
        run.destinationBookmark = bookmark
        run.recoveryState.destinationBookmark = bookmark
    }

    func reserveNextPublication(
        _ data: Data,
        for content: LibraryMarkdownBackupContent,
        in run: inout ActiveLibraryMarkdownBackupRun
    ) async throws -> LibraryMarkdownBackupRecoveryPublication {
        guard let sourceCursor = run.pendingSourceCursor else {
            preconditionFailure(
                "reserved backup content must retain its source cursor")
        }
        var candidateAllocator = run.allocator
        let reservation = LibraryMarkdownBackupRecoveryPublication(
            sequence: run.recoveryState.completedPublications.count,
            meetingID: content.meeting.id,
            fileName: candidateAllocator.nextFileName(for: content.meeting.title),
            sha256: ContentDigest.sha256(data),
            byteCount: data.count,
            sourceCursor: sourceCursor)
        var reservedState = run.recoveryState
        reservedState.pendingPublication = reservation
        try await applyRecovery(
            .reserve(reservation),
            operationID: run.recoveryState.operationID)
        run.allocator = candidateAllocator
        run.recoveryState = reservedState
        return reservation
    }

    func recordPublished(
        _ publication: LibraryMarkdownBackupRecoveryPublication,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        run.pending = nil
        run.pendingSourceCursor = nil
        run.exportedFileNames.append(publication.fileName)
        run.pendingJournalCompletion = publication
        try await completeJournalPublication(
            publication,
            in: &run,
            progress: progress)
    }

    func completeJournalPublication(
        _ publication: LibraryMarkdownBackupRecoveryPublication,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        try await applyRecovery(
            .complete(publication),
            operationID: run.recoveryState.operationID)
        run.recoveryState.completedPublications.append(publication)
        run.recoveryState.pendingPublication = nil
        run.pendingJournalCompletion = nil
        if let sourceCursor = publication.sourceCursor {
            run.pendingRecoveryCheckpoint = sourceCursor
            try await persistPendingRecoveryCheckpoint(
                in: &run,
                progress: progress)
        } else {
            await publishProgress(for: run, through: progress)
        }
    }

    func persistPendingRecoveryCheckpoint(
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        guard let cursor = run.pendingRecoveryCheckpoint else {
            preconditionFailure("backup recovery checkpoint must exist")
        }
        try await applyRecovery(
            .checkpointSource(cursor),
            operationID: run.recoveryState.operationID)
        run.recoveryState.sourceCursor = cursor
        run.pendingRecoveryCheckpoint = nil
        await publishProgress(for: run, through: progress)
    }

    func recordSourceFailure(
        _ sourceFailure: LibraryMarkdownBackupSourceFailure,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        try await recordFailure(
            Self.sourceFailure(sourceFailure),
            in: &run,
            progress: progress)
    }

    func recordDocumentFailure(
        for content: LibraryMarkdownBackupContent,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        try await recordFailure(
            Self.failure(for: content, stage: .document),
            in: &run,
            progress: progress)
    }

    func recordFailure(
        _ failure: LibraryMarkdownBackupFailure,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        guard let cursor = run.pendingSourceCursor else {
            preconditionFailure(
                "failed backup content must retain its source cursor")
        }
        let recoveryFailure = LibraryMarkdownBackupRecoveryFailure(
            sequence: run.recoveryState.failures.count,
            sourceCursor: cursor,
            meetingID: failure.meetingID,
            title: Self.boundedRecoveryTitle(failure.title),
            stage: failure.stage)
        try await applyRecovery(
            .recordFailure(recoveryFailure),
            operationID: run.recoveryState.operationID)
        run.recoveryState.failures.append(recoveryFailure)
        run.failures.append(recoveryFailure.failure)
        run.pending = nil
        run.pendingSourceCursor = nil
        run.pendingRecoveryCheckpoint = cursor
        try await persistPendingRecoveryCheckpoint(
            in: &run,
            progress: progress)
    }

    func recordPublicationFailure(
        for content: LibraryMarkdownBackupContent,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        if run.recoveryState.pendingPublication != nil {
            try await applyRecovery(
                .clearReservation,
                operationID: run.recoveryState.operationID)
            run.recoveryState.pendingPublication = nil
        }
        try await recordFailure(
            Self.failure(for: content, stage: .publication),
            in: &run,
            progress: progress)
    }

    func acquireDestination(
        _ bookmark: LibraryMarkdownBackupDestinationBookmark
    ) async throws -> any LibraryMarkdownBackupDestinationLease {
        do {
            return try await destinationAccess.acquire(bookmark: bookmark)
        } catch {
            throw LibraryMarkdownBackupError.destinationUnavailable
        }
    }

    func fileNameAllocator(in directory: URL) async throws -> BackupFileNameAllocator {
        BackupFileNameAllocator(existing: try await existingFileNames(in: directory))
    }

    func existingFileNames(in directory: URL) async throws -> Set<String> {
        do {
            return try await files.existingMarkdownFileNames(in: directory)
        } catch {
            throw LibraryMarkdownBackupError.destinationUnavailable
        }
    }

    func applyRecovery(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) async throws {
        do {
            try await recoveryStore.apply(
                mutation,
                operationID: operationID)
        } catch {
            throw BackupRecoveryPersistenceError()
        }
    }

    func removeRecovery(operationID: UUID) async throws {
        do {
            try await recoveryStore.remove(operationID: operationID)
        } catch {
            throw BackupRecoveryPersistenceError()
        }
    }

    func finishTermination(
        run: inout ActiveLibraryMarkdownBackupRun
    ) async throws -> LibraryMarkdownBackupExecution {
        guard let termination = run.pendingTermination else {
            preconditionFailure("backup termination must exist")
        }
        if termination == .completed,
           run.recoveryState.phase == .active {
            try await applyRecovery(
                .markCompleted,
                operationID: run.recoveryState.operationID)
            run.recoveryState.phase = .completed
        }
        try await removeRecovery(
            operationID: run.recoveryState.operationID)
        await run.source.close()
        activeRun = nil

        switch termination {
        case .completed:
            return .completed(LibraryMarkdownBackupResult(
                totalMeetings: run.totalMeetings,
                exportedFileNames: run.exportedFileNames,
                failures: run.failures))
        case .sourceFailure:
            throw LibraryMarkdownBackupError.libraryUnavailable
        }
    }

    func publishProgress(
        total: Int,
        exported: Int,
        failures: Int,
        through handler: LibraryMarkdownBackupProgressHandler
    ) async {
        await handler(.exporting(LibraryMarkdownBackupProgress(
            completedMeetings: exported + failures,
            totalMeetings: total,
            exportedMeetings: exported,
            failedMeetings: failures)))
    }

    func publishProgress(
        for run: ActiveLibraryMarkdownBackupRun,
        through handler: LibraryMarkdownBackupProgressHandler
    ) async {
        await publishProgress(
            total: run.totalMeetings,
            exported: run.exportedFileNames.count,
            failures: run.failures.count,
            through: handler)
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    static func sourceFailure(
        _ failure: LibraryMarkdownBackupSourceFailure
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: failure.meetingID,
            title: failure.title,
            stage: .source)
    }

    static func failure(
        for content: LibraryMarkdownBackupContent,
        stage: LibraryMarkdownBackupFailureStage
    ) -> LibraryMarkdownBackupFailure {
        LibraryMarkdownBackupFailure(
            meetingID: content.meeting.id,
            title: content.meeting.title,
            stage: stage)
    }

    static func boundedRecoveryTitle(_ title: String) -> String {
        let maximumBytes = LibraryMarkdownBackupRecoveryFailure.maximumTitleBytes
        guard title.utf8.count > maximumBytes else { return title }
        var bounded = ""
        bounded.reserveCapacity(maximumBytes)
        var byteCount = 0
        for scalar in title.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            guard byteCount + scalarByteCount <= maximumBytes else { break }
            bounded.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }
        return bounded
    }

}
