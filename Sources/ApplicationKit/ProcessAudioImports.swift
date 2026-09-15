import Foundation
import PortavozCore
import StorageKit

public struct ProcessAudioImportsRequest: Sendable {
    public let started: @Sendable (MeetingID) async -> Void
    public let progress: @Sendable (MeetingID, ImportMeetingProgress) async -> Void

    public init(started: @escaping @Sendable (MeetingID) async -> Void = { _ in },
                progress: @escaping @Sendable (MeetingID, ImportMeetingProgress) async -> Void = { _, _ in }) {
        self.started = started
        self.progress = progress
    }
}

/// Serial durable acquisition; the existing import use case still owns model
/// preparation, attribution, summary policy and release of model leases.
public struct ProcessAudioImports: ApplicationUseCase {
    let store: MeetingStore
    let files: any AudioImportFiles
    let makeProcessor: @Sendable () async -> any ImportMeetingProcessor
    let summaries: any ImportMeetingSummaryProviderResolver
    let now: @Sendable () -> Date
    let leaseDuration: TimeInterval
    let heartbeatInterval: Duration

    public init(
        store: MeetingStore, files: any AudioImportFiles,
        makeProcessor: @escaping @Sendable () async -> any ImportMeetingProcessor,
        summaries: any ImportMeetingSummaryProviderResolver,
        leaseDuration: TimeInterval = 120, heartbeatInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.files = files
        self.makeProcessor = makeProcessor
        self.summaries = summaries
        self.leaseDuration = leaseDuration
        self.heartbeatInterval = heartbeatInterval
        self.now = now
    }

    public func execute(_ request: ProcessAudioImportsRequest) async throws -> Int {
        guard leaseDuration.isFinite, leaseDuration > 0,
              heartbeatInterval > .zero, heartbeatInterval < .seconds(leaseDuration) else {
            throw StorageError.invalidProcessingJob("import heartbeat must precede lease expiry")
        }
        var processed = 0
        while !Task.isCancelled {
            // A resumed attempt gets a new owner even within the same process.
            let owner = UUID().uuidString
            guard let job = try await store.claimNextProcessingJob(
                kinds: [.audioImport], owner: owner, leaseDuration: leaseDuration, at: now()) else { break }
            do {
                await request.started(job.meetingID)
                try await executeOwned(job, owner: owner, request: request)
            } catch is CancellationError {
                // GRDB propagates caller cancellation before executing a
                // write. Cleanup needs its own cancellation lifetime, and we
                // join it before allowing the supervisor to start another run.
                let retirement = Task.detached(priority: .utility) {
                    try await suspendIfOwned(job, owner: owner)
                }
                try await retirement.value
                throw CancellationError()
            } catch {
                try await failIfOwned(job, owner: owner, error: error)
            }
            processed += 1
        }
        return processed
    }

    private func executeOwned(
        _ job: ProcessingJob, owner: String, request: ProcessAudioImportsRequest
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await process(job, owner: owner, request: request)
                return true
            }
            group.addTask {
                try await maintainLease(job, owner: owner)
                return false
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                if finished { return }
            }
        }
    }

    private func process(_ job: ProcessingJob, owner: String, request: ProcessAudioImportsRequest) async throws {
        let copy = try await files.withAcquisitionAccess {
            // A lease timeout does not stop an old native file write. The
            // filesystem exclusion spans this fresh read through publication.
            let input = try await store.audioImportInput(for: job.id, owner: owner, at: now())
            guard input.sourceBookmark != nil else { return try await files.verifyOwnedAudio(input) }
            let acquired = try await files.copySelectedAudio(input)
            try Task.checkCancellation()
            _ = try await store.publishAudioImportCopy(
                for: job.id, owner: owner, relativeDirectory: acquired.relativeDirectory,
                digest: acquired.digest, at: now())
            return acquired
        }
        try Task.checkCancellation()
        let input = try await store.audioImportInput(for: job.id, owner: owner, at: now())
        let processor = await makeProcessor()
        let useCase = ImportMeeting(
            audioFiles: OwnedImportAudio(copy: copy), preferences: OwnedImportPreferences(value: input.preferences),
            processor: processor, store: OwnedImportStore(store: store, job: job, owner: owner, copy: copy, now: now),
            summaryProviders: summaries, makeMeetingID: { job.meetingID }, now: now)
        _ = try await useCase.execute(ImportMeetingRequest(sourceURL: copy.fileURL, title: input.title) { phase in
            await request.progress(job.meetingID, phase)
        })
    }

    private func maintainLease(_ job: ProcessingJob, owner: String) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: heartbeatInterval)
            do {
                _ = try await store.heartbeatProcessingJob(
                    job.id, owner: owner, progress: 0.1, leaseDuration: leaseDuration, at: now())
            } catch {
                // Required content can finish before best-effort summary.
                // Re-read durable success instead of racing an in-memory flag.
                if try await currentJob(job)?.state == .succeeded { return }
                throw error
            }
        }
    }

    private func currentJob(_ job: ProcessingJob) async throws -> ProcessingJob? {
        try await store.processingJobs(for: job.meetingID).first { $0.id == job.id }
    }

    private func suspendIfOwned(_ job: ProcessingJob, owner: String) async throws {
        guard let current = try await currentJob(job), current.state == .running,
              current.leaseOwner == owner else { return }
        do {
            _ = try await store.suspendProcessingJob(job.id, owner: owner, at: now())
        } catch StorageError.processingJobLeaseLost { return }
    }

    private func failIfOwned(_ job: ProcessingJob, owner: String, error: Error) async throws {
        guard let current = try await currentJob(job), current.state == .running,
              current.leaseOwner == owner else { return }
        let code: String
        switch error {
        case AudioImportFileError.sourceChanged: code = "import.source.changed"
        case AudioImportFileError.sourceUnavailable: code = "import.source.unavailable"
        case AudioImportFileError.invalidOwnedCopy: code = "import.copy.invalid"
        case AudioImportFileError.acquisitionBusy: code = "import.copy.busy"
        default: code = "import.processing.failed"
        }
        do {
            _ = try await store.failProcessingJob(job.id, owner: owner, failure: .init(code: code), at: now())
        } catch StorageError.processingJobLeaseLost { return }
    }
}
