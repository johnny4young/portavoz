import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Accepts a reviewed quality-pass draft as one revision-fenced Unit of
    /// Work. Existing summaries remain immutable history.
    public func applyRefinedCast(
        for id: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        generationRun: GenerationRun? = nil
    ) async throws {
        let install = RefinedCastInstall(
            meetingID: id,
            expectedTranscriptRevision: expectedTranscriptRevision,
            language: language,
            speakers: speakers,
            segments: segments,
            generationRun: generationRun)
        try Self.validateRefinedCast(
            meetingID: id,
            expectedTranscriptRevision: expectedTranscriptRevision,
            speakers: speakers,
            segments: segments)
        if let generationRun {
            try Self.validateRefinedGenerationRun(
                generationRun,
                meetingID: id,
                expectedTranscriptRevision: expectedTranscriptRevision,
                language: language)
        }
        try await database.write { db in
            try Self.installRefinedCast(install, in: db)
        }
    }
}

private extension MeetingStore {
    static func installRefinedCast(
        _ install: RefinedCastInstall,
        in db: Database
    ) throws {
        let key = install.meetingID.rawValue.uuidString
        guard var meeting = try MeetingRecord
            .filter(Column("id") == key)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db)
        else { throw StorageError.meetingNotFound(install.meetingID) }
        guard meeting.transcriptRevision == install.expectedTranscriptRevision else {
            throw StorageError.staleRefineDraft(
                meetingID: install.meetingID,
                expected: install.expectedTranscriptRevision,
                actual: meeting.transcriptRevision)
        }
        try validateRefinedIdentities(
            meetingID: install.meetingID,
            speakers: install.speakers,
            segments: install.segments,
            in: db)

        let timestamp = Date()
        if let generationRun = install.generationRun {
            try GenerationRunRecord(generationRun).insert(db)
        }
        try tombstoneRefinedCast(meetingKey: key, at: timestamp, in: db)
        for speaker in install.speakers {
            try SpeakerRecord(speaker, createdAt: timestamp, updatedAt: timestamp).save(db)
        }
        for segment in install.segments {
            try SegmentRecord(
                segment,
                generationRunID: install.generationRun?.id,
                createdAt: timestamp,
                updatedAt: timestamp)
                .save(db)
        }
        meeting.language = install.language
        meeting.transcriptRevision += 1
        meeting.updatedAt = timestamp
        try meeting.update(db)
    }

    static func tombstoneRefinedCast(
        meetingKey: String,
        at timestamp: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? "
                + "WHERE meetingID = ? AND deletedAt IS NULL",
            arguments: [timestamp, timestamp, meetingKey])
        try db.execute(
            sql: "UPDATE speaker SET deletedAt = ?, updatedAt = ? "
                + "WHERE meetingID = ? AND deletedAt IS NULL",
            arguments: [timestamp, timestamp, meetingKey])
    }

    static func validateRefinedCast(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) throws {
        let speakerIDs = Set(speakers.map(\.id))
        guard expectedTranscriptRevision >= 0, !segments.isEmpty else {
            throw StorageError.invalidRefinedMeeting(
                "revision must be nonnegative and transcript must not be empty")
        }
        guard Set(speakers.map(\.id)).count == speakers.count,
            Set(segments.map(\.id)).count == segments.count,
            speakers.allSatisfy({ $0.meetingID == meetingID }),
            segments.allSatisfy({ segment in
                segment.meetingID == meetingID
                    && segment.speakerID.map(speakerIDs.contains) ?? true
            })
        else {
            throw StorageError.invalidRefinedMeeting(
                "children must be unique, meeting-owned, and reference the proposed cast")
        }
    }

    static func validateRefinedIdentities(
        meetingID: MeetingID,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        in db: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        for speaker in speakers {
            if let existing = try SpeakerRecord.fetchOne(
                db,
                key: speaker.id.rawValue.uuidString),
                existing.meetingID != key {
                throw StorageError.invalidRefinedMeeting(
                    "cannot move an existing speaker between meetings")
            }
        }
        for segment in segments {
            if let existing = try SegmentRecord.fetchOne(db, key: segment.id.uuidString),
                existing.meetingID != key {
                throw StorageError.invalidRefinedMeeting(
                    "cannot move an existing segment between meetings")
            }
        }
    }

    static func validateRefinedGenerationRun(
        _ run: GenerationRun,
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        language: String?
    ) throws {
        try validateTerminalGenerationRun(run)
        guard run.meetingID == meetingID,
              run.kind == .transcript,
              run.outcome == .succeeded,
              run.outputLanguage == language
        else {
            throw StorageError.invalidGenerationRun(
                "a linked transcript requires matching succeeded provenance")
        }
        guard let data = run.configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any],
              config["workflow"] as? String == "meeting-refine",
              config["sourceTranscriptRevision"] as? Int == expectedTranscriptRevision
        else {
            throw StorageError.invalidGenerationRun(
                "refine provenance does not match the source revision")
        }
    }
}

private struct RefinedCastInstall {
    let meetingID: MeetingID
    let expectedTranscriptRevision: Int
    let language: String?
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let generationRun: GenerationRun?
}
