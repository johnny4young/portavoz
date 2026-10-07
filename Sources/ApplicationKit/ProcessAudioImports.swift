import Foundation
import PortavozCore
import StorageKit

public struct ProcessAudioImportsRequest: Sendable {
    public let started: @Sendable (MeetingID) async -> Void
    public let progress: @Sendable (MeetingID, ImportMeetingProgress) async -> Void
    /// Called once per settled attempt (success or durable failure), so derived
    /// search projections need not wait for the whole queue to drain.
    public let completed: @Sendable (MeetingID) async -> Void

    public init(started: @escaping @Sendable (MeetingID) async -> Void = { _ in },
                progress: @escaping @Sendable (MeetingID, ImportMeetingProgress) async -> Void = { _, _ in },
                completed: @escaping @Sendable (MeetingID) async -> Void = { _ in }) {
        self.started = started
        self.progress = progress
        self.completed = completed
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
            } catch let error where error is CancellationError || Task.isCancelled {
                // A native capability may surface its own error once cancelled;
                // that is still cancellation, never a terminal import failure.
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
            await request.completed(job.meetingID)
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
            // The lease itself ignores tombstones. A trashed import stops its
            // file/model work here instead of finishing work that publication
            // must reject; `failIfOwned` then yields the lease for restore.
            if try await currentJob(job) == nil { throw AudioImportWorkerInterruption.meetingRemoved }
        }
    }

    private func currentJob(_ job: ProcessingJob) async throws -> ProcessingJob? {
        try await store.processingJobs(for: job.meetingID).first { $0.id == job.id }
    }

    private func suspendIfOwned(_ job: ProcessingJob, owner: String) async throws {
        guard let current = try await currentJob(job) else { return await yieldTrashedLease(job, owner: owner) }
        guard current.state == .running, current.leaseOwner == owner else { return }
        do {
            _ = try await store.suspendProcessingJob(job.id, owner: owner, at: now())
        } catch StorageError.processingJobLeaseLost { return }
    }

    /// Trashed (or purged) mid-attempt is not an import failure. Return the
    /// attempt to pending without spending its retry budget, so restoring the
    /// meeting resumes it; claims already skip tombstoned meetings.
    private func yieldTrashedLease(_ job: ProcessingJob, owner: String) async {
        _ = try? await store.suspendProcessingJob(job.id, owner: owner, at: now())
    }

    private func failIfOwned(_ job: ProcessingJob, owner: String, error: Error) async throws {
        guard let current = try await currentJob(job) else { return await yieldTrashedLease(job, owner: owner) }
        guard current.state == .running, current.leaseOwner == owner else { return }
        let code: String
        switch error {
        case AudioImportFileError.sourceChanged: code = "import.source.changed"
        case AudioImportFileError.sourceUnavailable: code = "import.source.unavailable"
        case AudioImportFileError.invalidOwnedCopy: code = "import.copy.invalid"
        case AudioImportFileError.acquisitionBusy: code = "import.copy.busy"
        default: code = "import.processing.failed"
        }
        // Contention with a purge or another acquisition is transient: back
        // off (5 s, 10 s, …, at most 60 s) and let the queue wake retry it
        // within the job's bounded attempts instead of failing terminally.
        var retryAt: Date?
        if (error as? AudioImportFileError) == .acquisitionBusy {
            let backoff = min(60, 5 * pow(2, Double(max(0, current.attempt - 1))))
            retryAt = now().addingTimeInterval(backoff)
        }
        let failed: ProcessingJob
        do {
            failed = try await store.failProcessingJob(
                job.id, owner: owner, failure: .init(code: code), retryAt: retryAt, at: now())
        } catch StorageError.processingJobLeaseLost { return }
        // Exhausted contention leaves the selected source valid: keep its
        // bookmark so explicit Retry can still reach the original.
        guard failed.state == .failed, retryAt == nil else { return }
        // A terminal failure before publication cannot resume without a fresh
        // selection. Retiring the bookmark is best-effort: the job is already
        // failed and its row is removed with the meeting.
        try? await store.retireFailedAudioImportSource(for: job.meetingID)
    }
}

private enum AudioImportWorkerInterruption: Error {
    case meetingRemoved
}
