import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Rebuilds the meeting's searchable corrected-text rows from correction
    /// history inside the caller's transaction, so search can never observe a
    /// correction write without its projection.
    ///
    /// Every path that changes correction state or the accepted transcript
    /// revision calls this: append, tombstone, replica merge, sync replay,
    /// refine, and re-transcription. The projection stays disposable — a
    /// deleted table converges on the next call.
    static func refreshSegmentCorrectedText(
        meetingID: MeetingID,
        in database: Database
    ) throws {
        let key = meetingID.rawValue.uuidString
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
