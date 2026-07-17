import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Inserts each logical operation once and advances its live meeting to
    /// `processing` in the same transaction. An existing idempotency key is
    /// returned unchanged; enqueue never resurrects terminal work.
    public func enqueueProcessingJobs(
        for meetingID: MeetingID,
        requests: [ProcessingJobRequest],
        at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        try Self.validateProcessingRequests(requests)
        let key = meetingID.rawValue.uuidString
        return try await database.write { db in
            guard
                let meeting = try MeetingRecord
                    .filter(Column("id") == key)
                    .filter(Column("deletedAt") == nil)
                    .fetchOne(db)
            else { throw StorageError.meetingNotFound(meetingID) }
            guard meeting.lifecycleState != MeetingLifecycleState.recording.rawValue else {
                throw StorageError.invalidProcessingJob(
                    "work cannot be enqueued before capture is installed")
            }

            let jobs = try requests.map { request in
                try Self.enqueueProcessingRequest(
                    request, meetingID: meetingID, timestamp: timestamp, in: db)
            }
            try Self.reconcileProcessingLifecycle(
                for: meetingID, at: timestamp, in: db)
            return jobs
        }
    }

    /// Durable jobs for a live meeting in creation order. Tombstoned or
    /// missing meetings expose no work through normal product projections.
    public func processingJobs(for meetingID: MeetingID) async throws -> [ProcessingJob] {
        let key = meetingID.rawValue.uuidString
        return try await database.read { db in
            guard
                try MeetingRecord
                    .filter(Column("id") == key)
                    .filter(Column("deletedAt") == nil)
                    .fetchCount(db) > 0
            else { return [] }
            return try ProcessingJobRecord
                .filter(Column("meetingID") == key)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
                .map { try $0.job }
        }
    }

    /// Explicit user retry for terminal durable failures. The logical job and
    /// idempotency key stay unchanged; only execution state is reset. Workers
    /// still revalidate the current input fingerprint before publishing.
    public func retryFailedProcessingJobs(
        for meetingID: MeetingID,
        at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        let key = meetingID.rawValue.uuidString
        return try await database.write { db in
            guard try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchCount(db) > 0
            else { throw StorageError.meetingNotFound(meetingID) }

            let records = try ProcessingJobRecord
                .filter(Column("meetingID") == key)
                .filter(Column("state") == ProcessingJobState.failed.rawValue)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
            var retried: [ProcessingJob] = []
            for var record in records {
                record.state = ProcessingJobState.pending.rawValue
                record.progress = 0
                record.attempt = 0
                record.notBefore = timestamp
                record.leaseOwner = nil
                record.leaseExpiresAt = nil
                record.errorCode = nil
                record.errorMessage = nil
                record.startedAt = nil
                record.finishedAt = nil
                record.updatedAt = timestamp
                try record.update(db)
                retried.append(try record.job)
            }
            try Self.reconcileProcessingLifecycle(
                for: meetingID, at: timestamp, in: db)
            return retried
        }
    }

    /// Atomically leases the highest-priority due job supported by a worker.
    /// A lease attempt increments exactly once and never claims deleted data.
    public func claimNextProcessingJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob? {
        try Self.validateWorker(owner, leaseDuration: leaseDuration)
        try Self.validateKinds(kinds)
        return try await database.write { db in
            guard var record = try Self.dueProcessingJob(
                kinds: kinds.map(\.rawValue), at: timestamp, in: db)
            else { return nil }

            record.state = ProcessingJobState.running.rawValue
            record.attempt += 1
            record.notBefore = nil
            record.leaseOwner = owner
            record.leaseExpiresAt = timestamp.addingTimeInterval(leaseDuration)
            record.errorCode = nil
            record.errorMessage = nil
            record.startedAt = record.startedAt ?? timestamp
            record.finishedAt = nil
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    /// Extends an owned, unexpired lease and records monotonic progress.
    public func heartbeatProcessingJob(
        _ id: ProcessingJobID,
        owner: String,
        progress: Double,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        try Self.validateWorker(owner, leaseDuration: leaseDuration)
        guard progress.isFinite, (0...1).contains(progress) else {
            throw StorageError.invalidProcessingJob("progress must be finite and between 0 and 1")
        }
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            guard progress >= record.progress else {
                throw StorageError.invalidProcessingJob("progress cannot move backwards")
            }
            record.progress = progress
            let proposedExpiry = timestamp.addingTimeInterval(leaseDuration)
            record.leaseExpiresAt = max(record.leaseExpiresAt ?? proposedExpiry, proposedExpiry)
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    /// Completes an owned attempt and derives the meeting's aggregate state
    /// from all of its durable jobs.
    public func completeProcessingJob(
        _ id: ProcessingJobID,
        owner: String,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        try Self.validateOwner(owner)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            guard !Self.requiresArtifactCommit(record.kind) else {
                throw StorageError.invalidProcessingJob(
                    "generated-content jobs require their domain artifact completion API")
            }
            let job = try Self.succeed(&record, at: timestamp, in: db)
            try Self.reconcileProcessingLifecycle(
                for: job.meetingID, at: timestamp, in: db)
            return job
        }
    }

    /// Publishes a complete transcript recovered from finalized capture audio,
    /// advances its revision, completes the owned transcription attempt, and
    /// admits dependent diarization in one transaction.
    public func completeTranscriptionJob(
        _ id: ProcessingJobID,
        owner: String,
        artifact: TranscriptionArtifact,
        enqueue followUpRequests: [ProcessingJobRequest] = [],
        at timestamp: Date = Date()
    ) async throws -> ProcessingArtifactCommit {
        try Self.validateOwner(owner)
        let transcript = TranscriptArtifactEnvelope(artifact)
        try Self.validateTranscriptArtifact(transcript)
        try Self.validateFollowUps(followUpRequests)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            try Self.validateArtifactJob(
                record, kind: .transcription, meetingID: artifact.meetingID,
                fingerprint: artifact.inputFingerprint)
            var meeting = try Self.liveMeeting(artifact.meetingID, in: db)
            try Self.requireRevision(
                artifact.sourceTranscriptRevision, for: record, meeting: meeting)
            try Self.requireTranscriptIdentities(transcript, in: db)
            try Self.writeTranscriptArtifact(
                transcript,
                meeting: &meeting,
                at: timestamp,
                in: db)
            let enqueued = try Self.enqueueFollowUps(
                followUpRequests, after: record, at: timestamp, in: db)
            let completed = try Self.succeed(&record, at: timestamp, in: db)
            try Self.reconcileProcessingLifecycle(
                for: artifact.meetingID, at: timestamp, in: db)
            return ProcessingArtifactCommit(
                completedJob: completed,
                enqueuedJobs: enqueued,
                artifactVersion: meeting.transcriptRevision)
        }
    }

    /// Publishes an attributed transcript, advances its revision, completes
    /// the owned diarization attempt, and optionally creates dependent work
    /// in one transaction. A changed source revision rejects the whole write.
    public func completeDiarizationJob(
        _ id: ProcessingJobID,
        owner: String,
        artifact: DiarizationArtifact,
        enqueue followUpRequests: [ProcessingJobRequest] = [],
        at timestamp: Date = Date()
    ) async throws -> ProcessingArtifactCommit {
        try Self.validateOwner(owner)
        let transcript = TranscriptArtifactEnvelope(artifact)
        try Self.validateTranscriptArtifact(transcript)
        try Self.validateFollowUps(followUpRequests)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            try Self.validateArtifactJob(
                record, kind: .diarization, meetingID: artifact.meetingID,
                fingerprint: artifact.inputFingerprint)
            var meeting = try Self.liveMeeting(artifact.meetingID, in: db)
            try Self.requireRevision(
                artifact.sourceTranscriptRevision, for: record, meeting: meeting)
            try Self.requireTranscriptIdentities(transcript, in: db)
            try Self.writeTranscriptArtifact(
                transcript,
                meeting: &meeting,
                at: timestamp,
                in: db)
            let enqueued = try Self.enqueueFollowUps(
                followUpRequests, after: record, at: timestamp, in: db)
            let completed = try Self.succeed(&record, at: timestamp, in: db)
            try Self.reconcileProcessingLifecycle(
                for: artifact.meetingID, at: timestamp, in: db)
            return ProcessingArtifactCommit(
                completedJob: completed,
                enqueuedJobs: enqueued,
                artifactVersion: meeting.transcriptRevision)
        }
    }

    /// Inserts generation provenance plus an immutable summary snapshot and
    /// completes its owned job in one transaction. The material-cache
    /// fingerprint on `SummaryDraft` is preserved, while the separate
    /// operation fingerprint fences both the job and its generation run.
    public func completeSummaryJob(
        _ id: ProcessingJobID,
        owner: String,
        artifact: SummaryArtifact,
        enqueue followUpRequests: [ProcessingJobRequest] = [],
        at timestamp: Date = Date()
    ) async throws -> ProcessingArtifactCommit {
        try Self.validateOwner(owner)
        try Self.validateSummaryArtifact(artifact)
        try Self.validateFollowUps(followUpRequests)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            try Self.validateArtifactJob(
                record, kind: .summary, meetingID: artifact.draft.meetingID,
                fingerprint: artifact.inputFingerprint)
            let meeting = try Self.liveMeeting(artifact.draft.meetingID, in: db)
            try Self.requireRevision(
                artifact.sourceTranscriptRevision, for: record, meeting: meeting)
            try Self.requireSummaryOwners(artifact.draft, in: db)
            let version = try Self.insertGeneratedSummary(
                artifact.draft,
                generationRun: artifact.generationRun,
                at: timestamp,
                in: db)
            let enqueued = try Self.enqueueFollowUps(
                followUpRequests, after: record, at: timestamp, in: db)
            let completed = try Self.succeed(&record, at: timestamp, in: db)
            try Self.reconcileProcessingLifecycle(
                for: artifact.draft.meetingID, at: timestamp, in: db)
            return ProcessingArtifactCommit(
                completedJob: completed,
                enqueuedJobs: enqueued,
                artifactVersion: version)
        }
    }

    /// Releases a failed attempt for a scheduled retry while attempts remain;
    /// otherwise the job becomes terminal and its meeting needs attention.
    public func failProcessingJob(
        _ id: ProcessingJobID,
        owner: String,
        failure: ProcessingJobFailure,
        retryAt: Date? = nil,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        try Self.validateOwner(owner)
        try Self.validateFailure(failure)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            let willRetry = retryAt != nil && record.attempt < record.maxAttempts
            record.state = willRetry
                ? ProcessingJobState.pending.rawValue
                : ProcessingJobState.failed.rawValue
            record.progress = willRetry ? 0 : record.progress
            record.notBefore = willRetry ? retryAt : nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = failure.code
            record.errorMessage = failure.message
            record.finishedAt = willRetry ? nil : timestamp
            record.updatedAt = timestamp
            try record.update(db)
            let job = try record.job
            try Self.reconcileProcessingLifecycle(
                for: job.meetingID, at: timestamp, in: db)
            return job
        }
    }

    /// Cancels optional or superseded work through its owned lease. A
    /// cancellation is terminal but is not an aggregate failure: once no
    /// other work or capture publication remains unresolved, the meeting can
    /// become ready without pretending that an artifact was generated.
    public func cancelProcessingJob(
        _ id: ProcessingJobID,
        owner: String,
        reason: ProcessingJobFailure,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        try Self.validateOwner(owner)
        try Self.validateFailure(reason)
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            record.state = ProcessingJobState.cancelled.rawValue
            record.notBefore = nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = reason.code
            record.errorMessage = reason.message
            record.finishedAt = timestamp
            record.updatedAt = timestamp
            try record.update(db)
            let job = try record.job
            try Self.reconcileProcessingLifecycle(
                for: job.meetingID, at: timestamp, in: db)
            return job
        }
    }

    /// Earliest durable wake-up for the worker's supported kinds. Immediately
    /// due jobs are claimed before this query; only future `notBefore` values
    /// are returned, so an idle process does not need to poll SQLite.
    public func nextScheduledProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date = Date()
    ) async throws -> Date? {
        try Self.validateKinds(kinds)
        return try await database.read { db in
            let record = try ProcessingJobRecord
                .filter(Column("state") == ProcessingJobState.pending.rawValue)
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
                .filter(Column("notBefore") != nil)
                .filter(Column("notBefore") > timestamp)
                .filter(sql: "attempt < maxAttempts")
                .filter(sql: """
                    EXISTS (
                        SELECT 1 FROM meeting
                        WHERE meeting.id = processingJob.meetingID
                          AND meeting.deletedAt IS NULL
                    )
                    """)
                .order(Column("notBefore"), Column("createdAt"), Column("id"))
                .fetchOne(db)
            return record?.notBefore
        }
    }

    /// Repeat-safe lease recovery primitive for the launch reconciler. An
    /// interrupted attempt becomes due again, or terminal after exhaustion.
    @discardableResult
    public func recoverExpiredProcessingJobs(
        at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        try await database.write { db in
            let expired = try ProcessingJobRecord
                .filter(Column("state") == ProcessingJobState.running.rawValue)
                .filter(sql: "leaseExpiresAt <= ?", arguments: [timestamp])
                .fetchAll(db)
            var recovered: [ProcessingJob] = []
            var meetingIDs: Set<MeetingID> = []
            for var record in expired {
                let canRetry = record.attempt < record.maxAttempts
                record.state = canRetry
                    ? ProcessingJobState.pending.rawValue
                    : ProcessingJobState.failed.rawValue
                record.progress = canRetry ? 0 : record.progress
                record.notBefore = canRetry ? timestamp : nil
                record.leaseOwner = nil
                record.leaseExpiresAt = nil
                record.errorCode = canRetry
                    ? "processing.lease.expired" : "processing.lease.exhausted"
                record.errorMessage = "The previous worker stopped before releasing its lease."
                record.finishedAt = canRetry ? nil : timestamp
                record.updatedAt = timestamp
                try record.update(db)
                let job = try record.job
                recovered.append(job)
                meetingIDs.insert(job.meetingID)
            }
            for meetingID in meetingIDs {
                try Self.reconcileProcessingLifecycle(
                    for: meetingID, at: timestamp, in: db)
            }
            return recovered
        }
    }
}

extension MeetingStore {
    static func enqueueProcessingRequest(
        _ request: ProcessingJobRequest,
        meetingID: MeetingID,
        timestamp: Date,
        in db: Database
    ) throws -> ProcessingJob {
        let meetingKey = meetingID.rawValue.uuidString
        if let existing = try ProcessingJobRecord
            .filter(Column("meetingID") == meetingKey)
            .filter(Column("kind") == request.kind.rawValue)
            .filter(Column("inputFingerprint") == request.inputFingerprint)
            .fetchOne(db) {
            return try existing.job
        }
        let job = ProcessingJob(
            meetingID: meetingID,
            kind: request.kind,
            inputFingerprint: request.inputFingerprint,
            priority: request.priority,
            maxAttempts: request.maxAttempts,
            notBefore: request.notBefore,
            createdAt: timestamp)
        let record = ProcessingJobRecord(job)
        try record.insert(db)
        return job
    }

    private static func dueProcessingJob(
        kinds: [String],
        at timestamp: Date,
        in db: Database
    ) throws -> ProcessingJobRecord? {
        try ProcessingJobRecord
            .filter(Column("state") == ProcessingJobState.pending.rawValue)
            .filter(kinds.contains(Column("kind")))
            .filter(sql: "(notBefore IS NULL OR notBefore <= ?)", arguments: [timestamp])
            .filter(sql: "attempt < maxAttempts")
            .filter(sql: """
                EXISTS (
                    SELECT 1 FROM meeting
                    WHERE meeting.id = processingJob.meetingID
                      AND meeting.deletedAt IS NULL
                )
                """)
            .order(Column("priority").desc, Column("createdAt"), Column("id"))
            .fetchOne(db)
    }

    private static func ownedJob(
        _ id: ProcessingJobID,
        owner: String,
        at timestamp: Date,
        in db: Database
    ) throws -> ProcessingJobRecord {
        guard let record = try ProcessingJobRecord.fetchOne(
            db, key: id.rawValue.uuidString)
        else { throw StorageError.processingJobNotFound(id) }
        guard record.state == ProcessingJobState.running.rawValue,
            record.leaseOwner == owner,
            let expiry = record.leaseExpiresAt,
            expiry > timestamp
        else { throw StorageError.processingJobLeaseLost(id) }
        return record
    }

    static func reconcileProcessingLifecycle(
        for meetingID: MeetingID,
        at timestamp: Date,
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        guard var meeting = try MeetingRecord.fetchOne(db, key: key), meeting.deletedAt == nil else {
            return
        }
        let jobs = try ProcessingJobRecord
            .filter(Column("meetingID") == key)
            .fetchAll(db)
        let pendingCaptureCount = try AudioAssetRecord
            .filter(Column("meetingID") == key)
            .filter(Column("role") == AudioAssetRole.capture.rawValue)
            .filter(Column("deletedAt") == nil)
            .filter(Column("healthStatus") == AudioAssetHealthStatus.pending.rawValue)
            .fetchCount(db)
        if jobs.contains(where: { $0.state == ProcessingJobState.pending.rawValue
            || $0.state == ProcessingJobState.running.rawValue }) {
            meeting.lifecycleState = MeetingLifecycleState.processing.rawValue
            meeting.lastProcessingError = nil
        } else if let failure = jobs
            .filter({ $0.state == ProcessingJobState.failed.rawValue })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            meeting.lifecycleState = MeetingLifecycleState.needsAttention.rawValue
            meeting.lastProcessingError = failure.errorCode ?? "processing.failed"
        } else if pendingCaptureCount > 0 {
            meeting.lifecycleState = MeetingLifecycleState.needsAttention.rawValue
            meeting.lastProcessingError = "capture.publication.failed"
        } else if !jobs.isEmpty {
            meeting.lifecycleState = MeetingLifecycleState.ready.rawValue
            meeting.lastProcessingError = nil
        }
        meeting.updatedAt = timestamp
        try meeting.update(db)
    }

    static func validateProcessingRequests(
        _ requests: [ProcessingJobRequest]
    ) throws {
        guard !requests.isEmpty else {
            throw StorageError.invalidProcessingJob("at least one request is required")
        }
        var keys: Set<String> = []
        for request in requests {
            guard isCanonical(request.kind.rawValue),
                isCanonical(request.inputFingerprint),
                request.maxAttempts > 0
            else {
                throw StorageError.invalidProcessingJob(
                    "kind/fingerprint must be canonical and maxAttempts must be positive")
            }
            let key = "\(request.kind.rawValue)\u{0}\(request.inputFingerprint)"
            guard keys.insert(key).inserted else {
                throw StorageError.invalidProcessingJob(
                    "a request batch cannot repeat an idempotency key")
            }
        }
    }

    private static func validateFollowUps(_ requests: [ProcessingJobRequest]) throws {
        guard !requests.isEmpty else { return }
        try validateProcessingRequests(requests)
    }

    private static func requiresArtifactCommit(_ kind: String) -> Bool {
        kind == ProcessingJobKind.transcription.rawValue
            || kind == ProcessingJobKind.refine.rawValue
            || kind == ProcessingJobKind.diarization.rawValue
            || kind == ProcessingJobKind.summary.rawValue
    }

    private static func validateWorker(
        _ owner: String,
        leaseDuration: TimeInterval
    ) throws {
        try validateOwner(owner)
        guard leaseDuration.isFinite, leaseDuration > 0 else {
            throw StorageError.invalidProcessingJob("lease duration must be finite and positive")
        }
    }

    private static func validateKinds(_ kinds: Set<ProcessingJobKind>) throws {
        guard !kinds.isEmpty, kinds.allSatisfy({ isCanonical($0.rawValue) }) else {
            throw StorageError.invalidProcessingJob(
                "worker kinds must be canonical and non-empty")
        }
    }

    private static func validateFailure(_ failure: ProcessingJobFailure) throws {
        guard isCanonical(failure.code) else {
            throw StorageError.invalidProcessingJob(
                "failure code must be canonical and non-empty")
        }
    }

    private static func validateOwner(_ owner: String) throws {
        guard isCanonical(owner) else {
            throw StorageError.invalidProcessingJob("lease owner must be canonical and non-empty")
        }
    }

    static func isCanonical(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MeetingStore {
    private static func validateSummaryArtifact(_ artifact: SummaryArtifact) throws {
        let draft = artifact.draft
        guard isCanonical(artifact.inputFingerprint),
            artifact.generationRun.inputFingerprint == artifact.inputFingerprint,
            artifact.sourceTranscriptRevision >= 0,
            isCanonical(draft.recipeID),
            isCanonical(draft.language),
            hasContent(draft.markdown),
            draft.fingerprint.map(isCanonical) == true,
            Set(draft.actionItems.map(\.id)).count == draft.actionItems.count,
            draft.actionItems.allSatisfy({ hasContent($0.text) })
        else {
            throw StorageError.invalidProcessingJob(
                "summary artifact must include canonical identity, content, and cache evidence")
        }
    }

    private static func validateArtifactJob(
        _ record: ProcessingJobRecord,
        kind: ProcessingJobKind,
        meetingID: MeetingID,
        fingerprint: String
    ) throws {
        guard record.kind == kind.rawValue,
            record.meetingID == meetingID.rawValue.uuidString,
            record.inputFingerprint == fingerprint
        else {
            throw StorageError.invalidProcessingJob(
                "artifact kind, meeting, and fingerprint must match the owned job")
        }
    }

    private static func liveMeeting(
        _ meetingID: MeetingID,
        in db: Database
    ) throws -> MeetingRecord {
        guard let meeting = try MeetingRecord
            .filter(Column("id") == meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db)
        else { throw StorageError.meetingNotFound(meetingID) }
        return meeting
    }

    private static func requireRevision(
        _ expected: Int,
        for job: ProcessingJobRecord,
        meeting: MeetingRecord
    ) throws {
        guard meeting.transcriptRevision == expected else {
            let id = ProcessingJobID(rawValue: try PersistedIdentity.required(
                job.id, table: ProcessingJobRecord.databaseTableName, column: "id"))
            throw StorageError.processingJobInputChanged(id)
        }
    }

    private static func requireSummaryOwners(
        _ draft: SummaryDraft,
        in db: Database
    ) throws {
        let owners = Set(draft.actionItems.compactMap(\.ownerSpeakerID))
        guard !owners.isEmpty else { return }
        let liveSpeakerIDs = try SpeakerRecord
            .filter(Column("meetingID") == draft.meetingID.rawValue.uuidString)
            .filter(Column("deletedAt") == nil)
            .fetchAll(db)
            .map { try $0.speaker.id }
        guard owners.isSubset(of: Set(liveSpeakerIDs)) else {
            throw StorageError.invalidProcessingJob(
                "summary action owners must belong to the current live cast")
        }
    }

    private static func enqueueFollowUps(
        _ requests: [ProcessingJobRequest],
        after current: ProcessingJobRecord,
        at timestamp: Date,
        in db: Database
    ) throws -> [ProcessingJob] {
        let currentJob = try current.job
        for request in requests where request.kind == currentJob.kind
            && request.inputFingerprint == currentJob.inputFingerprint {
            throw StorageError.invalidProcessingJob(
                "a job cannot enqueue itself as dependent work")
        }
        return try requests.map {
            try enqueueProcessingRequest(
                $0, meetingID: currentJob.meetingID, timestamp: timestamp, in: db)
        }
    }

    private static func succeed(
        _ record: inout ProcessingJobRecord,
        at timestamp: Date,
        in db: Database
    ) throws -> ProcessingJob {
        record.state = ProcessingJobState.succeeded.rawValue
        record.progress = 1
        record.notBefore = nil
        record.leaseOwner = nil
        record.leaseExpiresAt = nil
        record.errorCode = nil
        record.errorMessage = nil
        record.finishedAt = timestamp
        record.updatedAt = timestamp
        try record.update(db)
        return try record.job
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
