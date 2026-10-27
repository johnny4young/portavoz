import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Requests a translation of the exact reading named by `fingerprint`. An active job is
    /// returned as is and a settled one runs again. The meeting lifecycle is never changed.
    public func requestTranscriptTranslation(
        for meetingID: MeetingID,
        fingerprint: String,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        let request = ProcessingJobRequest(
            kind: .transcriptTranslation, inputFingerprint: fingerprint, priority: -1, maxAttempts: 2)
        try Self.validateProcessingRequests([request])
        return try await database.write { db in
            let meeting = try Self.liveMeeting(meetingID, in: db)
            guard meeting.lifecycleState != MeetingLifecycleState.recording.rawValue else {
                throw StorageError.invalidProcessingJob("a meeting cannot be translated while it records")
            }
            if var existing = try ProcessingJobRecord
                .filter(Column("meetingID") == meeting.id)
                .filter(Column("kind") == request.kind.rawValue)
                .filter(Column("inputFingerprint") == fingerprint)
                .fetchOne(db) {
                guard existing.state != ProcessingJobState.pending.rawValue,
                      existing.state != ProcessingJobState.running.rawValue else { return try existing.job }
                existing.resetForExplicitRetry(at: timestamp)
                try existing.update(db)
                return try existing.job
            }
            return try Self.enqueueProcessingRequest(request, meetingID: meetingID, timestamp: timestamp, in: db)
        }
    }

    /// Stops pending or running translations. A running worker loses its lease, so its
    /// result is never published.
    public func cancelTranscriptTranslation(for meetingID: MeetingID, at timestamp: Date = Date()) async throws {
        try await database.write { db in
            let records = try ProcessingJobRecord
                .filter(Column("meetingID") == meetingID.rawValue.uuidString)
                .filter(Column("kind") == ProcessingJobKind.transcriptTranslation.rawValue)
                .filter([ProcessingJobState.pending.rawValue, ProcessingJobState.running.rawValue]
                    .contains(Column("state")))
                .fetchAll(db)
            for var record in records {
                record.state = ProcessingJobState.cancelled.rawValue
                record.notBefore = nil
                record.leaseOwner = nil
                record.leaseExpiresAt = nil
                record.errorCode = "translation.cancelled"
                record.errorMessage = nil
                record.finishedAt = timestamp
                record.updatedAt = timestamp
                try record.update(db)
            }
        }
    }

    /// Row boundaries check the same live ownership required by publication, without
    /// renewing or mutating a lease that may have been cancelled or reclaimed.
    public func validateTranscriptTranslationLease(
        _ id: ProcessingJobID, owner: String, at timestamp: Date
    ) async throws {
        try Self.validateOwner(owner)
        try await database.read { db in
            _ = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
        }
    }

    /// Publishes a translation and completes its owned job in one transaction, only while
    /// the transcript revision and correction overlay it read are still current.
    public func completeTranscriptTranslationJob(
        _ id: ProcessingJobID,
        owner: String,
        artifact: TranscriptTranslationArtifact,
        at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        try Self.validateOwner(owner)
        let translation = artifact.translation
        guard TranscriptTranslation.languages.contains(translation.targetLanguage),
              translation.lines.values.allSatisfy({ line in
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && line.count <= TranscriptTranslation.maximumLineLength
              }) else {
            throw StorageError.invalidProcessingJob("a translation needs a supported language and non-empty lines")
        }
        return try await database.write { db in
            var record = try Self.ownedJob(id, owner: owner, at: timestamp, in: db)
            try Self.validateArtifactJob(
                record, kind: .transcriptTranslation, meetingID: translation.meetingID,
                fingerprint: artifact.inputFingerprint)
            let meeting = try Self.liveMeeting(translation.meetingID, in: db)
            try Self.requireRevision(translation.sourceTranscriptRevision, for: record, meeting: meeting)
            guard try Self.fetchMeetingReviewCore(translation.meetingID, in: db)?.correctionRevision
                == translation.sourceCorrectionRevision else {
                throw StorageError.processingJobInputChanged(id)
            }
            try Self.replaceTranscriptTranslation(translation, at: timestamp, in: db)
            return try Self.succeed(&record, at: timestamp, in: db)
        }
    }

    /// The transcript reading a translation is built from, with its correction revision.
    public func transcriptTranslationSource(_ meetingID: MeetingID) async throws -> MeetingReviewCore? {
        try await database.read { db in try Self.fetchMeetingReviewCore(meetingID, in: db) }
    }

    public func transcriptTranslations(for meetingID: MeetingID) async throws -> [TranscriptTranslation] {
        try await database.read { db in try Self.fetchTranscriptTranslations(meetingID, in: db) }
    }

    public func observeTranscriptTranslations(
        _ meetingID: MeetingID
    ) -> AsyncThrowingStream<[TranscriptTranslation], Error> {
        observedStream(ValueObservation.tracking(
            regions: [Table("meeting"), Table("transcriptTranslation"), Table("transcriptTranslationLine")],
            fetch: { db in try Self.fetchTranscriptTranslations(meetingID, in: db) }))
    }

    static func fetchTranscriptTranslations(
        _ meetingID: MeetingID, in db: Database
    ) throws -> [TranscriptTranslation] {
        let key = meetingID.rawValue.uuidString
        guard try MeetingRecord.filter(Column("id") == key).filter(Column("deletedAt") == nil).fetchCount(db) > 0
        else { return [] }
        let headers = try Row.fetchAll(db, sql: """
            SELECT targetLanguage, sourceTranscriptRevision, sourceCorrectionRevision, createdAt
            FROM transcriptTranslation WHERE meetingID = ? ORDER BY targetLanguage
            """, arguments: [key])
        return try headers.map { header in
            let language: String = header["targetLanguage"]
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowID, text FROM transcriptTranslationLine WHERE meetingID = ? AND targetLanguage = ?
                """, arguments: [key, language])
            var lines: [UUID: String] = [:]
            for row in rows {
                let rowID: String = row["rowID"]
                guard let id = UUID(uuidString: rowID) else {
                    throw StorageError.invalidProcessingJob("a translated line has an invalid row identity")
                }
                lines[id] = row["text"]
            }
            let revision: String = header["sourceCorrectionRevision"]
            guard let correctionRevision = TranscriptCorrectionRevision(rawValue: revision) else {
                throw StorageError.invalidProcessingJob("a translation has an invalid correction revision")
            }
            return TranscriptTranslation(
                meetingID: meetingID, targetLanguage: language,
                sourceTranscriptRevision: header["sourceTranscriptRevision"],
                sourceCorrectionRevision: correctionRevision, lines: lines, createdAt: header["createdAt"])
        }
    }

    private static func replaceTranscriptTranslation(
        _ translation: TranscriptTranslation, at timestamp: Date, in db: Database
    ) throws {
        let key = translation.meetingID.rawValue.uuidString
        try db.execute(
            sql: "DELETE FROM transcriptTranslation WHERE meetingID = ? AND targetLanguage = ?",
            arguments: [key, translation.targetLanguage])
        try db.execute(sql: """
            INSERT INTO transcriptTranslation (
                meetingID, targetLanguage, sourceTranscriptRevision, sourceCorrectionRevision, createdAt)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                key, translation.targetLanguage, translation.sourceTranscriptRevision,
                translation.sourceCorrectionRevision.rawValue, timestamp
            ])
        for (rowID, text) in translation.lines {
            try db.execute(sql: """
                INSERT INTO transcriptTranslationLine (meetingID, targetLanguage, rowID, text)
                VALUES (?, ?, ?, ?)
                """, arguments: [key, translation.targetLanguage, rowID.uuidString, text])
        }
    }
}
