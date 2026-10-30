import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Trimming is destructive: on top of compression's owner and import
    /// checks, the meeting must be settled, with no derived job in flight.
    public func canTrimMeetingAudio(
        meetingID: MeetingID,
        relativeAudioDirectory: String
    ) async throws -> Bool {
        guard try await canCompressMeetingAudio(relativeAudioDirectory: relativeAudioDirectory) else {
            return false
        }
        return try await database.read { db in
            let key = meetingID.rawValue.uuidString
            guard let meeting = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db),
                meeting.audioDirectory == relativeAudioDirectory,
                meeting.lifecycleState == MeetingLifecycleState.ready.rawValue
            else { return false }
            let activeJobs = try ProcessingJobRecord
                .filter(Column("meetingID") == key)
                .filter([ProcessingJobState.pending.rawValue, ProcessingJobState.running.rawValue]
                    .contains(Column("state")))
                .fetchCount(db)
            return activeJobs == 0
        }
    }

    /// Ends the transcript at `cutoff` seconds in one revision-fenced write:
    /// later rows are tombstoned, a row crossing the cut is clipped (keeping
    /// its identity and embedding), and the meeting ends there. Admission is
    /// rechecked in this write because staging can yield to newly queued work.
    public func trimMeetingTail(
        meetingID: MeetingID,
        expectedTranscriptRevision: Int,
        cutoff: TimeInterval
    ) async throws {
        guard cutoff.isFinite, cutoff > 0 else { throw StorageError.invalidTrimCutoff(cutoff) }
        try await database.write { db in
            let key = meetingID.rawValue.uuidString
            guard var meeting = try MeetingRecord
                .filter(Column("id") == key)
                .filter(Column("deletedAt") == nil)
                .fetchOne(db)
            else { throw StorageError.meetingNotFound(meetingID) }
            guard meeting.transcriptRevision == expectedTranscriptRevision else {
                throw StorageError.staleRefineDraft(
                    meetingID: meetingID,
                    expected: expectedTranscriptRevision,
                    actual: meeting.transcriptRevision)
            }
            let activeJobs = try ProcessingJobRecord
                .filter(Column("meetingID") == key)
                .filter([ProcessingJobState.pending.rawValue, ProcessingJobState.running.rawValue]
                    .contains(Column("state")))
                .fetchCount(db)
            guard meeting.lifecycleState == MeetingLifecycleState.ready.rawValue,
                activeJobs == 0
            else { throw StorageError.audioTrimUnavailable(meetingID) }
            let timestamp = Date()
            try db.execute(
                sql: "UPDATE segment SET deletedAt = ?, updatedAt = ? "
                    + "WHERE meetingID = ? AND deletedAt IS NULL AND startTime >= ?",
                arguments: [timestamp, timestamp, key, cutoff])
            try db.execute(
                sql: "UPDATE segment SET endTime = ?, updatedAt = ? "
                    + "WHERE meetingID = ? AND deletedAt IS NULL AND endTime > ?",
                arguments: [cutoff, timestamp, key, cutoff])
            meeting.endedAt = meeting.startedAt.addingTimeInterval(cutoff)
            meeting.transcriptRevision += 1
            meeting.updatedAt = timestamp
            try meeting.update(db)
            // The revision bump retires prior corrections; their search rows go too.
            try Self.refreshTranscriptCorrectionSearchProjection(meetingID: meetingID, in: db)
        }
    }
}
