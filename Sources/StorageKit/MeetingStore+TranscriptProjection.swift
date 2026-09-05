import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// SQL predicate shared by every accepted-only retrieval path. Corrected
    /// source rows fail closed until that consumer explicitly adopts composed
    /// transcript material; unaffected rows remain immediately searchable.
    static let acceptedSegmentHasNoActiveCorrectionSQL = """
        NOT EXISTS (
            SELECT 1
            FROM transcriptCorrectionTarget AS correctionTarget
            JOIN transcriptCorrection AS correction
              ON correction.id = correctionTarget.correctionID
            WHERE correctionTarget.segmentID = segment.id
              AND correction.meetingID = segment.meetingID
              AND correction.baseTranscriptRevision = (
                  SELECT currentMeeting.transcriptRevision
                  FROM meeting AS currentMeeting
                  WHERE currentMeeting.id = segment.meetingID
              )
              AND correction.deletedAt IS NULL
              AND correction.kind <> 'restore'
              AND NOT EXISTS (
                  SELECT 1
                  FROM transcriptCorrection AS successor
                  WHERE successor.supersedesCorrectionID = correction.id
              )
        )
        """

    /// The search-lane variant (T28b/D313): only corrections that change what
    /// text exists — replaceText and the structural kinds — remove a segment
    /// from accepted-text serving. An active `changeSpeaker` leaves the text
    /// untouched, so the line (and its unchanged embedding) stays findable.
    /// Text-replaced segments are served from `segmentCorrectedText` instead.
    /// Evidence and continuity lanes keep the stricter predicate above.
    static let acceptedSegmentHasNoActiveTextCorrectionSQL = """
        NOT EXISTS (
            SELECT 1
            FROM transcriptCorrectionTarget AS correctionTarget
            JOIN transcriptCorrection AS correction
              ON correction.id = correctionTarget.correctionID
            WHERE correctionTarget.segmentID = segment.id
              AND correction.meetingID = segment.meetingID
              AND correction.baseTranscriptRevision = (
                  SELECT currentMeeting.transcriptRevision
                  FROM meeting AS currentMeeting
                  WHERE currentMeeting.id = segment.meetingID
              )
              AND correction.deletedAt IS NULL
              AND correction.kind IN ('replaceText', 'split', 'merge', 'suppress')
              AND NOT EXISTS (
                  SELECT 1
                  FROM transcriptCorrection AS successor
                  WHERE successor.supersedesCorrectionID = correction.id
              )
        )
        """

    static func transcriptCorrectionRevision(
        meetingID: MeetingID,
        in database: Database
    ) throws -> TranscriptCorrectionRevision {
        guard let record = try MeetingRecord.fetchOne(
            database,
            key: meetingID.rawValue.uuidString)
        else { throw StorageError.meetingNotFound(meetingID) }
        let meeting = try record.meeting
        return try currentCorrectionRevision(
            meetingID: meetingID,
            transcriptRevision: meeting.transcriptRevision,
            in: database)
    }

    static func currentCorrectionRevision(
        meetingID: MeetingID,
        transcriptRevision: Int,
        in database: Database
    ) throws -> TranscriptCorrectionRevision {
        try TranscriptCorrectionRevision.current(
            meetingID: meetingID,
            baseTranscriptRevision: transcriptRevision,
            history: fetchTranscriptCorrectionHistory(
                meetingID: meetingID,
                in: database))
    }

    /// One correction transaction invalidates only accepted-only derivations.
    /// The immutable correction tables remain the authority; source generation
    /// advances so a restored row can be indexed later without polling.
    static func invalidateAcceptedOnlyDerivedWork(
        meetingID: MeetingID,
        previous: TranscriptCorrectionRevision,
        current: TranscriptCorrectionRevision,
        at timestamp: Date,
        in database: Database
    ) throws {
        guard previous != current else { return }
        let key = meetingID.rawValue.uuidString
        let meetingTimestamp = try Date.fetchOne(
            database,
            sql: "SELECT updatedAt FROM meeting WHERE id = ?",
            arguments: [key]) ?? timestamp
        let jobTimestamp = try Date.fetchOne(
            database,
            sql: "SELECT MAX(updatedAt) FROM processingJob WHERE meetingID = ?",
            arguments: [key]) ?? timestamp
        let semanticSourceTimestamp = try Date.fetchOne(
            database,
            sql: "SELECT updatedAt FROM derivedMaintenanceSource WHERE kind = ?",
            arguments: ["semantic-corpus"]) ?? timestamp
        let maintenanceTimestamp = max(
            timestamp,
            meetingTimestamp,
            jobTimestamp,
            semanticSourceTimestamp)
        try database.execute(
            sql: """
                UPDATE processingJob
                SET state = 'cancelled',
                    notBefore = NULL,
                    leaseOwner = NULL,
                    leaseExpiresAt = NULL,
                    errorCode = 'processing.input.superseded',
                    errorMessage = 'Transcript corrections changed the derived input.',
                    finishedAt = ?,
                    updatedAt = ?
                WHERE meetingID = ?
                  AND kind IN ('summary', 'index')
                  AND state IN ('pending', 'running')
                """,
            arguments: [
                maintenanceTimestamp,
                maintenanceTimestamp,
                key
            ])
        let cancelledJobs = database.changesCount
        try database.execute(
            sql: """
                UPDATE derivedMaintenanceSource
                SET sourceGeneration = sourceGeneration + 1,
                    updatedAt = ?
                WHERE kind = 'semantic-corpus'
                """,
            arguments: [maintenanceTimestamp])
        if cancelledJobs > 0 {
            try reconcileProcessingLifecycle(
                for: meetingID,
                at: maintenanceTimestamp,
                in: database)
        }
    }
}
