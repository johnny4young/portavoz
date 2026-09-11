import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Earliest durable wake-up for the worker's supported kinds. Immediately
    /// due jobs are claimed before this query; only future retry dates and
    /// lease expirations are returned, so an idle process does not poll SQLite.
    public func nextScheduledProcessingDate(
        kinds: Set<ProcessingJobKind>,
        after timestamp: Date = Date()
    ) async throws -> Date? {
        try Self.validateKinds(kinds)
        let rawKinds = kinds.map(\.rawValue)
        let placeholders = databaseQuestionMarks(count: rawKinds.count)
        return try await database.read { db in
            // A running job's lease expiry is a wake-up too. Without it a
            // worker that died mid-job leaves its meeting in `processing` with
            // nothing scheduled to reclaim the lease, so the spinner never
            // clears until some unrelated event happens to run a claim. This
            // mirrors `nextScheduledDerivedMaintenanceDate`.
            let liveMeeting = """
                EXISTS (
                    SELECT 1 FROM meeting
                    WHERE meeting.id = processingJob.meetingID
                      AND meeting.deletedAt IS NULL
                )
                """
            return try Date.fetchOne(
                db,
                sql: """
                    SELECT MIN(wakeAt) FROM (
                        SELECT notBefore AS wakeAt
                        FROM processingJob
                        WHERE state = 'pending'
                          AND kind IN (\(placeholders))
                          AND notBefore IS NOT NULL
                          AND notBefore > ?
                          AND attempt < maxAttempts
                          AND \(liveMeeting)
                        UNION ALL
                        SELECT leaseExpiresAt AS wakeAt
                        FROM processingJob
                        WHERE state = 'running'
                          AND kind IN (\(placeholders))
                          AND leaseExpiresAt IS NOT NULL
                          AND leaseExpiresAt > ?
                          AND \(liveMeeting)
                    )
                    """,
                arguments: StatementArguments(rawKinds + [timestamp] + rawKinds + [timestamp]))
        }
    }

    /// Repeat-safe lease recovery primitive for the launch reconciler. An
    /// interrupted attempt becomes due again, or terminal after exhaustion.
    @discardableResult
    public func recoverExpiredProcessingJobs(
        at timestamp: Date = Date()
    ) async throws -> [ProcessingJob] {
        try await database.write { db in
            try Self.recoverExpiredProcessingJobs(at: timestamp, in: db)
        }
    }

    /// Reclaims leases whose owner died without releasing them.
    ///
    /// Callable inside an existing write so a claim can recover first: launch
    /// recovery alone is not enough, because a worker that dies mid-job leaves
    /// 90–120 s of lease behind, and an immediate relaunch recovers nothing.
    @discardableResult
    static func recoverExpiredProcessingJobs(
        at timestamp: Date,
        in db: Database
    ) throws -> [ProcessingJob] {
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
