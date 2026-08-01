import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Idempotently admits the current semantic source generation for one
    /// embedding profile. The job records ownership only; NULL vectors remain
    /// the authoritative replay cursor.
    public func admitSemanticCorpusMaintenance(
        targetFingerprint: String,
        maxAttempts: Int = 3,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try Self.validateDerivedFingerprint(targetFingerprint)
        guard maxAttempts > 0 else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "max attempts must be positive")
        }
        return try await database.write { db in
            let generation = try Self.semanticCorpusGeneration(in: db)
            guard let fingerprint = SemanticCorpusMaintenanceFingerprint.compute(
                targetFingerprint: targetFingerprint,
                sourceGeneration: generation)
            else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "operation fingerprint inputs are invalid")
            }
            try db.execute(
                sql: """
                    UPDATE derivedMaintenanceJob
                    SET state = 'cancelled',
                        notBefore = NULL,
                        errorCode = NULL,
                        finishedAt = ?,
                        updatedAt = ?
                    WHERE kind = ?
                      AND state = 'pending'
                      AND operationFingerprint <> ?
                    """,
                arguments: [
                    timestamp,
                    timestamp,
                    DerivedMaintenanceKind.semanticCorpus.rawValue,
                    fingerprint
                ])
            let job = DerivedMaintenanceJob(
                kind: .semanticCorpus,
                targetFingerprint: targetFingerprint.lowercased(),
                sourceGeneration: generation,
                operationFingerprint: fingerprint,
                maxAttempts: maxAttempts,
                createdAt: timestamp,
                updatedAt: timestamp)
            try DerivedMaintenanceJobRecord(job).insert(
                db, onConflict: .ignore)
            guard let record = try DerivedMaintenanceJobRecord
                .filter(Column("kind") == DerivedMaintenanceKind.semanticCorpus.rawValue)
                .filter(Column("operationFingerprint") == fingerprint)
                .fetchOne(db)
            else {
                throw StorageError.invalidDerivedMaintenanceJob(
                    "admitted operation could not be reloaded")
            }
            return try record.job
        }
    }

    /// Claims at most one due job for the active profile. A live lease for the
    /// same derived kind excludes another process even if the profile changed.
    public func claimSemanticCorpusMaintenance(
        targetFingerprint: String,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob? {
        try Self.validateDerivedFingerprint(targetFingerprint)
        try Self.validateDerivedOwner(owner)
        guard leaseDuration.isFinite, leaseDuration > 0 else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "lease duration must be positive and finite")
        }
        return try await database.write { db in
            _ = try Self.recoverExpiredDerivedMaintenanceJobs(
                at: timestamp, in: db)
            let kind = DerivedMaintenanceKind.semanticCorpus.rawValue
            let liveOwner = try DerivedMaintenanceJobRecord
                .filter(Column("kind") == kind)
                .filter(Column("state") == DerivedMaintenanceJobState.running.rawValue)
                .filter(Column("leaseExpiresAt") > timestamp)
                .fetchCount(db)
            guard liveOwner == 0 else { return nil }

            guard var record = try DerivedMaintenanceJobRecord
                .filter(Column("kind") == kind)
                .filter(Column("targetFingerprint") == targetFingerprint.lowercased())
                .filter(Column("state") == DerivedMaintenanceJobState.pending.rawValue)
                .filter(Column("attempt") < Column("maxAttempts"))
                .filter(sql: "notBefore IS NULL OR notBefore <= ?", arguments: [timestamp])
                .order(Column("sourceGeneration"), Column("createdAt"), Column("id"))
                .fetchOne(db)
            else { return nil }

            record.state = DerivedMaintenanceJobState.running.rawValue
            record.attempt += 1
            record.notBefore = nil
            record.leaseOwner = owner
            record.leaseExpiresAt = timestamp.addingTimeInterval(leaseDuration)
            record.startedAt = record.startedAt ?? timestamp
            record.finishedAt = nil
            record.errorCode = nil
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    public func heartbeatSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date = Date()
    ) async throws {
        try Self.validateDerivedOwner(owner)
        guard leaseDuration.isFinite, leaseDuration > 0 else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "lease duration must be positive and finite")
        }
        try await database.write { db in
            var record = try Self.ownedDerivedMaintenanceJob(
                id, owner: owner, at: timestamp, in: db)
            record.leaseExpiresAt = timestamp.addingTimeInterval(leaseDuration)
            record.updatedAt = timestamp
            try record.update(db)
        }
    }

    /// Expected policy suspension returns the work to pending and refunds the
    /// claim attempt. No timer can consume retries while capture is protected.
    public func suspendSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try Self.validateDerivedOwner(owner)
        return try await database.write { db in
            var record = try Self.ownedDerivedMaintenanceJob(
                id, owner: owner, at: timestamp, in: db)
            record.state = DerivedMaintenanceJobState.pending.rawValue
            record.attempt = max(0, record.attempt - 1)
            record.notBefore = nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = nil
            record.finishedAt = nil
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    public func completeSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try Self.validateDerivedOwner(owner)
        return try await database.write { db in
            var record = try Self.ownedDerivedMaintenanceJob(
                id, owner: owner, at: timestamp, in: db)
            record.state = DerivedMaintenanceJobState.succeeded.rawValue
            record.notBefore = nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = nil
            record.finishedAt = timestamp
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    /// Records one bounded failure. Retryable work keeps no lease and exposes
    /// one future wake; the final attempt becomes an inert terminal record.
    public func failSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        errorCode: String,
        retryAt: Date,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        try Self.validateDerivedOwner(owner)
        try Self.validateDerivedCode(errorCode)
        return try await database.write { db in
            var record = try Self.ownedDerivedMaintenanceJob(
                id, owner: owner, at: timestamp, in: db)
            let canRetry = record.attempt < record.maxAttempts
            record.state = canRetry
                ? DerivedMaintenanceJobState.pending.rawValue
                : DerivedMaintenanceJobState.failed.rawValue
            record.notBefore = canRetry ? max(retryAt, timestamp) : nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = errorCode
            record.finishedAt = canRetry ? nil : timestamp
            record.updatedAt = timestamp
            try record.update(db)
            return try record.job
        }
    }

    @discardableResult
    public func recoverExpiredSemanticCorpusMaintenance(
        at timestamp: Date = Date()
    ) async throws -> Int {
        try await database.write { db in
            try Self.recoverExpiredDerivedMaintenanceJobs(
                at: timestamp, in: db)
        }
    }

    public func nextScheduledSemanticCorpusMaintenanceDate(
        after timestamp: Date = Date()
    ) async throws -> Date? {
        try await database.read { db in
            try Date.fetchOne(
                db,
                sql: """
                    SELECT MIN(wakeAt)
                    FROM (
                        SELECT notBefore AS wakeAt
                        FROM derivedMaintenanceJob
                        WHERE kind = ?
                          AND state = 'pending'
                          AND attempt < maxAttempts
                          AND notBefore > ?
                        UNION ALL
                        SELECT leaseExpiresAt AS wakeAt
                        FROM derivedMaintenanceJob
                        WHERE kind = ?
                          AND state = 'running'
                          AND leaseExpiresAt > ?
                    )
                    """,
                arguments: [
                    DerivedMaintenanceKind.semanticCorpus.rawValue,
                    timestamp,
                    DerivedMaintenanceKind.semanticCorpus.rawValue,
                    timestamp
                ])
        }
    }

    public func hasDueSemanticCorpusMaintenance(
        targetFingerprint: String,
        at timestamp: Date = Date()
    ) async throws -> Bool {
        try Self.validateDerivedFingerprint(targetFingerprint)
        return try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM derivedMaintenanceJob
                        WHERE kind = ?
                          AND targetFingerprint = ?
                          AND state = 'pending'
                          AND attempt < maxAttempts
                          AND (notBefore IS NULL OR notBefore <= ?)
                    )
                    """,
                arguments: [
                    DerivedMaintenanceKind.semanticCorpus.rawValue,
                    targetFingerprint.lowercased(),
                    timestamp
                ]) ?? false
        }
    }

    public func derivedMaintenanceJobs(
        kind: DerivedMaintenanceKind
    ) async throws -> [DerivedMaintenanceJob] {
        try await database.read { db in
            try DerivedMaintenanceJobRecord
                .filter(Column("kind") == kind.rawValue)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(db)
                .map { try $0.job }
        }
    }

    private static func semanticCorpusGeneration(in db: Database) throws -> Int {
        guard let generation = try Int.fetchOne(
            db,
            sql: "SELECT sourceGeneration FROM derivedMaintenanceSource WHERE kind = ?",
            arguments: [DerivedMaintenanceKind.semanticCorpus.rawValue])
        else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "semantic source generation is missing")
        }
        return generation
    }

    private static func ownedDerivedMaintenanceJob(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date,
        in db: Database
    ) throws -> DerivedMaintenanceJobRecord {
        guard let record = try DerivedMaintenanceJobRecord.fetchOne(
            db, key: id.rawValue.uuidString)
        else { throw StorageError.derivedMaintenanceJobNotFound(id) }
        guard record.state == DerivedMaintenanceJobState.running.rawValue,
              record.leaseOwner == owner,
              let expiry = record.leaseExpiresAt,
              expiry > timestamp
        else { throw StorageError.derivedMaintenanceJobLeaseLost(id) }
        return record
    }

    private static func recoverExpiredDerivedMaintenanceJobs(
        at timestamp: Date,
        in db: Database
    ) throws -> Int {
        let records = try DerivedMaintenanceJobRecord
            .filter(Column("kind") == DerivedMaintenanceKind.semanticCorpus.rawValue)
            .filter(Column("state") == DerivedMaintenanceJobState.running.rawValue)
            .filter(Column("leaseExpiresAt") <= timestamp)
            .fetchAll(db)
        for var record in records {
            let canRetry = record.attempt < record.maxAttempts
            record.state = canRetry
                ? DerivedMaintenanceJobState.pending.rawValue
                : DerivedMaintenanceJobState.failed.rawValue
            record.notBefore = canRetry ? timestamp : nil
            record.leaseOwner = nil
            record.leaseExpiresAt = nil
            record.errorCode = "maintenance.worker.expired"
            record.finishedAt = canRetry ? nil : timestamp
            record.updatedAt = timestamp
            try record.update(db)
        }
        return records.count
    }

    private static func validateDerivedFingerprint(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "target fingerprint must be a SHA-256 digest")
        }
    }

    private static func validateDerivedOwner(_ value: String) throws {
        guard isCanonicalDerivedValue(value) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "lease owner must be canonical")
        }
    }

    private static func validateDerivedCode(_ value: String) throws {
        guard isCanonicalDerivedValue(value) else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "error code must be canonical")
        }
    }

    private static func isCanonicalDerivedValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value && !trimmed.isEmpty && trimmed.count <= 256
    }
}
