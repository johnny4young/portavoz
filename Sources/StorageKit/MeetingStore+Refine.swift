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
        segments: [TranscriptSegment]
    ) async throws {
        try Self.validateRefinedCast(
            meetingID: id,
            expectedTranscriptRevision: expectedTranscriptRevision,
            speakers: speakers,
            segments: segments)
        let key = id.rawValue.uuidString
        try await database.write { db in
            guard var meeting = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.meetingNotFound(id) }
            guard meeting.transcriptRevision == expectedTranscriptRevision else {
                throw StorageError.staleRefineDraft(
                    meetingID: id,
                    expected: expectedTranscriptRevision,
                    actual: meeting.transcriptRevision)
            }
            try Self.validateRefinedIdentities(
                meetingID: id,
                speakers: speakers,
                segments: segments,
                in: db)

            let timestamp = Date()
            try db.execute(
                sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? "
                    + "WHERE meetingID = ? AND deletedAt IS NULL",
                arguments: [timestamp, timestamp, key])
            try db.execute(
                sql: "UPDATE speaker SET deletedAt = ?, updatedAt = ? "
                    + "WHERE meetingID = ? AND deletedAt IS NULL",
                arguments: [timestamp, timestamp, key])
            for speaker in speakers {
                try SpeakerRecord(
                    speaker,
                    createdAt: timestamp,
                    updatedAt: timestamp)
                    .save(db)
            }
            for segment in segments {
                try SegmentRecord(
                    segment,
                    createdAt: timestamp,
                    updatedAt: timestamp)
                    .save(db)
            }
            meeting.language = language
            meeting.transcriptRevision += 1
            meeting.updatedAt = timestamp
            try meeting.update(db)
        }
    }
}

private extension MeetingStore {
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
}
