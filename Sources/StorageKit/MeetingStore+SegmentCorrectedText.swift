import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Rebuilds the meeting's sparse correction lineage and searchable
    /// corrected-text rows inside the caller's transaction. Search and
    /// Spotlight can therefore never observe a correction write without the
    /// revision fence used to admit its derived material.
    ///
    /// Every path that changes correction state or the accepted transcript
    /// revision calls this: append, tombstone, replica merge, sync replay,
    /// refine, and re-transcription. The projection stays disposable — deleted
    /// rows converge on the next call.
    static func refreshTranscriptCorrectionSearchProjection(
        meetingID: MeetingID,
        in database: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
        // v33 invokes this same rebuild before v36 has created the sparse
        // lineage table. Keep that historical migration independently
        // runnable; v36 repeats the rebuild immediately after creating it.
        let hasCorrectionState = try database.tableExists(
            "transcriptCorrectionSearchState")
        if hasCorrectionState {
            try database.execute(
                sql: "DELETE FROM transcriptCorrectionSearchState WHERE meetingID = ?",
                arguments: [key])
        }
        try database.execute(
            sql: "DELETE FROM segmentCorrectedText WHERE meetingID = ?",
            arguments: [key])
        guard let revision = try Int.fetchOne(
            database,
            sql: "SELECT transcriptRevision FROM meeting WHERE id = ?",
            arguments: [key])
        else { return }
        let history = try fetchTranscriptCorrectionHistory(
            meetingID: meetingID,
            in: database)
        let correctionRevision = try TranscriptCorrectionRevision.current(
            meetingID: meetingID,
            baseTranscriptRevision: revision,
            history: history)
        if hasCorrectionState, !correctionRevision.isAccepted {
            try database.execute(
                sql: """
                    INSERT INTO transcriptCorrectionSearchState
                        (meetingID, baseTranscriptRevision, correctionRevision)
                    VALUES (?, ?, ?)
                    """,
                arguments: [key, revision, correctionRevision.rawValue])
        }
        let replacements = SegmentCorrectedTextProjection.activeReplacements(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: revision)
        for replacement in replacements {
            // INSERT…SELECT keeps the row out when the segment is tombstoned:
            // corrected text must never resurrect an unavailable source line.
            try database.execute(
                sql: """
                    INSERT INTO segmentCorrectedText
                        (segmentID, meetingID, correctionID,
                         baseTranscriptRevision, text, language, updatedAt)
                    SELECT segment.id, segment.meetingID, ?, ?, ?, ?, ?
                    FROM segment
                    WHERE segment.id = ?
                      AND segment.meetingID = ?
                      AND segment.deletedAt IS NULL
                    """,
                arguments: [
                    replacement.correctionID.uuidString,
                    revision,
                    replacement.text,
                    replacement.language,
                    replacement.updatedAt,
                    replacement.segmentID.uuidString,
                    key
                ])
        }
    }
}
