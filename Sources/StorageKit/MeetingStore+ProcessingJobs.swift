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
        try Self.validate(requests)
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
                try Self.enqueue(
                    request, meetingID: meetingID, timestamp: timestamp, in: db)
            }
            try Self.reconcileLifecycle(for: meetingID, at: timestamp, in: db)
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

    /// Atomically leases the highest-priority due job supported by a worker.
    /// A lease attempt increments exactly once and never claims deleted data.
    public func claimNextProcessingJob(
        kinds: Set<ProcessingJobKind>,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob? {
        try Self.validateWorker(owner, leaseDuration: leaseDuration)
        guard !kinds.isEmpty, kinds.allSatisfy({ Self.isCanonical($0.rawValue) }) else {
            throw StorageError.invalidProcessingJob("worker kinds must be canonical and non-empty")
        }
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
            let job = try record.job
            try Self.reconcileLifecycle(for: job.meetingID, at: timestamp, in: db)
            return job
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
        guard Self.isCanonical(failure.code) else {
            throw StorageError.invalidProcessingJob("failure code must be canonical and non-empty")
        }
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
            try Self.reconcileLifecycle(for: job.meetingID, at: timestamp, in: db)
            return job
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
                try Self.reconcileLifecycle(for: meetingID, at: timestamp, in: db)
            }
            return recovered
        }
    }
}

extension MeetingStore {
    private static func enqueue(
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

    private static func reconcileLifecycle(
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
        if jobs.contains(where: { $0.state == ProcessingJobState.pending.rawValue
            || $0.state == ProcessingJobState.running.rawValue }) {
            meeting.lifecycleState = MeetingLifecycleState.processing.rawValue
            meeting.lastProcessingError = nil
        } else if let failure = jobs
            .filter({ $0.state == ProcessingJobState.failed.rawValue })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            meeting.lifecycleState = MeetingLifecycleState.needsAttention.rawValue
            meeting.lastProcessingError = failure.errorCode ?? "processing.failed"
        } else if !jobs.isEmpty {
            meeting.lifecycleState = MeetingLifecycleState.ready.rawValue
            meeting.lastProcessingError = nil
        }
        meeting.updatedAt = timestamp
        try meeting.update(db)
    }

    private static func validate(_ requests: [ProcessingJobRequest]) throws {
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

    private static func validateWorker(
        _ owner: String,
        leaseDuration: TimeInterval
    ) throws {
        try validateOwner(owner)
        guard leaseDuration.isFinite, leaseDuration > 0 else {
            throw StorageError.invalidProcessingJob("lease duration must be finite and positive")
        }
    }

    private static func validateOwner(_ owner: String) throws {
        guard isCanonical(owner) else {
            throw StorageError.invalidProcessingJob("lease owner must be canonical and non-empty")
        }
    }

    fileprivate static func isCanonical(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
