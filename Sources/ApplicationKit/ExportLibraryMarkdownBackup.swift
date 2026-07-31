import Foundation
import PortavozCore
import StorageKit

/// One storage-independent meeting document used by the whole-library backup.
public struct LibraryMarkdownBackupContent: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let summaryVersion: Int?

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        summaryVersion: Int?
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.summaryVersion = summaryVersion
    }
}

/// A corrupt live aggregate is reported without exposing a storage error or
/// preventing healthy meetings from being backed up.
public struct LibraryMarkdownBackupSourceFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String

    public init(meetingID: MeetingID?, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public enum LibraryMarkdownBackupSourceEntry: Sendable {
    case content(LibraryMarkdownBackupContent)
    case failure(LibraryMarkdownBackupSourceFailure)
}

public protocol LibraryMarkdownBackupSourceSession: Sendable {
    var id: UUID { get }
    var totalMeetings: Int { get }
    func next() async throws -> LibraryMarkdownBackupSourceEntry?
    func close() async
}

public enum LibraryMarkdownBackupSourcePreparation: Sendable {
    case ready(any LibraryMarkdownBackupSourceSession)
    case suspended
}

/// Creates one read-consistent, incrementally consumed projection of the live
/// library. Storage corruption remains isolated per aggregate.
public protocol LibraryMarkdownBackupStore: Sendable {
    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation
}

extension MeetingStore: LibraryMarkdownBackupStore {
    public func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        switch try await prepareLibraryMarkdownBackupStage(
            mayContinue: mayContinue
        ) {
        case .ready(let stage):
            return .ready(MeetingStoreLibraryMarkdownBackupSource(stage: stage))
        case .suspended:
            return .suspended
        }
    }
}

private actor MeetingStoreLibraryMarkdownBackupSource:
    LibraryMarkdownBackupSourceSession {
    nonisolated let id: UUID
    nonisolated let totalMeetings: Int
    private let stage: MeetingMarkdownBackupStage

    init(stage: MeetingMarkdownBackupStage) {
        self.stage = stage
        id = stage.id
        totalMeetings = stage.totalMeetings
    }

    func next() async throws -> LibraryMarkdownBackupSourceEntry? {
        guard let entry = try await stage.next() else { return nil }
        switch entry {
        case .meeting(let snapshot):
            return .content(LibraryMarkdownBackupContent(
                meeting: snapshot.meeting,
                speakers: snapshot.speakers,
                segments: snapshot.segments,
                summary: snapshot.summary,
                summaryVersion: snapshot.summaryVersion))
        case .failure(let failure):
            return .failure(LibraryMarkdownBackupSourceFailure(
                meetingID: failure.meetingID,
                title: failure.title))
        }
    }

    func close() async {
        await stage.close()
    }
}

/// External Markdown rendering remains behind an app adapter so
/// IntegrationsKit never leaks into Settings presentation.
public protocol LibraryMarkdownBackupDocuments: Sendable {
    func markdownDocument(for content: LibraryMarkdownBackupContent) async throws -> Data
}

public enum LibraryMarkdownBackupPublication: Equatable, Sendable {
    case published
    case nameCollision
}

/// Filesystem capability. Implementations must publish complete files with a
/// same-directory atomic move and must never replace an existing destination.
public protocol LibraryMarkdownBackupFiles: Sendable {
    func existingMarkdownFileNames(in directory: URL) async throws -> Set<String>
    func publishMarkdownDocument(
        _ data: Data,
        named fileName: String,
        in directory: URL
    ) async throws -> LibraryMarkdownBackupPublication
}

public enum LibraryMarkdownBackupFailureStage: String, Equatable, Sendable {
    case source
    case document
    case publication
}

public struct LibraryMarkdownBackupFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String
    public let stage: LibraryMarkdownBackupFailureStage

    public init(
        meetingID: MeetingID?,
        title: String,
        stage: LibraryMarkdownBackupFailureStage
    ) {
        self.meetingID = meetingID
        self.title = title
        self.stage = stage
    }
}

public struct LibraryMarkdownBackupResult: Equatable, Sendable {
    public let totalMeetings: Int
    public let exportedFileNames: [String]
    public let failures: [LibraryMarkdownBackupFailure]

    public init(
        totalMeetings: Int,
        exportedFileNames: [String],
        failures: [LibraryMarkdownBackupFailure]
    ) {
        self.totalMeetings = totalMeetings
        self.exportedFileNames = exportedFileNames
        self.failures = failures
    }

    public var exportedCount: Int { exportedFileNames.count }
}

public enum LibraryMarkdownBackupExecution: Equatable, Sendable {
    case completed(LibraryMarkdownBackupResult)
    case suspended
}

public struct LibraryMarkdownBackupProgress: Equatable, Sendable {
    public let completedMeetings: Int
    public let totalMeetings: Int
    public let exportedMeetings: Int
    public let failedMeetings: Int

    public init(
        completedMeetings: Int,
        totalMeetings: Int,
        exportedMeetings: Int,
        failedMeetings: Int
    ) {
        self.completedMeetings = completedMeetings
        self.totalMeetings = totalMeetings
        self.exportedMeetings = exportedMeetings
        self.failedMeetings = failedMeetings
    }
}

public enum LibraryMarkdownBackupProgressEvent: Equatable, Sendable {
    case preparing
    case exporting(LibraryMarkdownBackupProgress)
}

public typealias LibraryMarkdownBackupProgressHandler =
    @Sendable (LibraryMarkdownBackupProgressEvent) async -> Void

public enum LibraryMarkdownBackupError: Error, Equatable, Sendable {
    case libraryUnavailable
    case destinationUnavailable
    case operationInProgress
}

public struct ExportLibraryMarkdownBackupRequest: Sendable {
    public let directory: URL
    public let progress: LibraryMarkdownBackupProgressHandler

    public init(
        directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler = { _ in }
    ) {
        self.directory = directory
        self.progress = progress
    }
}

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
        if let publication = run.pendingJournalCompletion {
            try await completeJournalPublication(
                publication,
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
            await render(
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
        do {
            entry = try await run.source.next()
        } catch {
            run.pendingTermination = .sourceFailure
            return try await finishTermination(run: &run)
        }
        guard let entry else {
            run.pendingTermination = .completed
            return try await finishTermination(run: &run)
        }
        switch entry {
        case .content(let content):
            run.pending = .content(content)
        case .failure(let failure):
            run.failures.append(Self.sourceFailure(failure))
            await publishProgress(for: run, through: progress)
        }
        return nil
    }

    func render(
        _ content: LibraryMarkdownBackupContent,
        into run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async {
        do {
            run.pending = .document(
                content,
                try await documents.markdownDocument(for: content))
        } catch {
            run.pending = nil
            run.failures.append(Self.failure(
                for: content,
                stage: .document))
            await publishProgress(for: run, through: progress)
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
        var candidateAllocator = run.allocator
        let reservation = LibraryMarkdownBackupRecoveryPublication(
            sequence: run.recoveryState.completedPublications.count,
            meetingID: content.meeting.id,
            fileName: candidateAllocator.nextFileName(for: content.meeting.title),
            sha256: ContentDigest.sha256(data),
            byteCount: data.count)
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
        await publishProgress(for: run, through: progress)
    }

    func recordPublicationFailure(
        for content: LibraryMarkdownBackupContent,
        in run: inout ActiveLibraryMarkdownBackupRun,
        progress: LibraryMarkdownBackupProgressHandler
    ) async throws {
        try await applyRecovery(
            .clearReservation,
            operationID: run.recoveryState.operationID)
        run.pending = nil
        run.failures.append(Self.failure(
            for: content,
            stage: .publication))
        run.recoveryState.pendingPublication = nil
        await publishProgress(for: run, through: progress)
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
        do {
            return BackupFileNameAllocator(
                existing: try await files.existingMarkdownFileNames(in: directory))
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

}
