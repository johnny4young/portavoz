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
        let correctedTextColumns = try Set(
            database.columns(in: "segmentCorrectedText").map(\.name))
        let hasEmbeddingColumns = correctedTextColumns.isSuperset(
            of: ["embedding", "embeddingFingerprint"])
        let existingEmbeddings = try preservedCorrectedEmbeddings(
            meetingID: meetingID,
            hasEmbeddingColumns: hasEmbeddingColumns,
            in: database)
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
            let preserved = existingEmbeddings[replacement.segmentID].flatMap { existing in
                existing.matches(
                    correctionID: replacement.correctionID,
                    baseTranscriptRevision: revision,
                    text: replacement.text,
                    language: replacement.language) ? existing : nil
            }
            // INSERT…SELECT keeps the row out when the segment is tombstoned:
            // corrected text must never resurrect an unavailable source line.
            try insertCorrectedText(
                replacement,
                baseTranscriptRevision: revision,
                meetingKey: key,
                hasEmbeddingColumns: hasEmbeddingColumns,
                preservedEmbedding: preserved,
                in: database)
        }
    }

    private static func preservedCorrectedEmbeddings(
        meetingID: MeetingID,
        hasEmbeddingColumns: Bool,
        in database: Database
    ) throws -> [UUID: PreservedCorrectedEmbedding] {
        guard hasEmbeddingColumns else { return [:] }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segmentID, correctionID, baseTranscriptRevision,
                       text, language, embedding, embeddingFingerprint
                FROM segmentCorrectedText
                WHERE meetingID = ?
                  AND embedding IS NOT NULL
                  AND embeddingFingerprint IS NOT NULL
                """,
            arguments: [meetingID.rawValue.uuidString])
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            let segmentID = try PersistedIdentity.required(
                row["segmentID"], table: "segmentCorrectedText", column: "segmentID")
            let correctionID = try PersistedIdentity.required(
                row["correctionID"], table: "segmentCorrectedText", column: "correctionID")
            return (segmentID, PreservedCorrectedEmbedding(
                correctionID: correctionID,
                baseTranscriptRevision: row["baseTranscriptRevision"],
                text: row["text"],
                language: row["language"],
                embedding: row["embedding"],
                embeddingFingerprint: row["embeddingFingerprint"]))
        })
    }

    private static func insertCorrectedText(
        _ replacement: SegmentCorrectedText,
        baseTranscriptRevision: Int,
        meetingKey: String,
        hasEmbeddingColumns: Bool,
        preservedEmbedding: PreservedCorrectedEmbedding?,
        in database: Database
    ) throws {
        if hasEmbeddingColumns {
            try database.execute(
                sql: """
                    INSERT INTO segmentCorrectedText
                        (segmentID, meetingID, correctionID,
                         baseTranscriptRevision, text, language, updatedAt,
                         embedding, embeddingFingerprint)
                    SELECT segment.id, segment.meetingID, ?, ?, ?, ?, ?, ?, ?
                    FROM segment
                    WHERE segment.id = ?
                      AND segment.meetingID = ?
                      AND segment.deletedAt IS NULL
                    """,
                arguments: [
                    replacement.correctionID.uuidString,
                    baseTranscriptRevision,
                    replacement.text,
                    replacement.language,
                    replacement.updatedAt,
                    preservedEmbedding?.embedding,
                    preservedEmbedding?.embeddingFingerprint,
                    replacement.segmentID.uuidString,
                    meetingKey
                ])
        } else {
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
                    baseTranscriptRevision,
                    replacement.text,
                    replacement.language,
                    replacement.updatedAt,
                    replacement.segmentID.uuidString,
                    meetingKey
                ])
        }
    }
}

private struct PreservedCorrectedEmbedding {
    let correctionID: UUID
    let baseTranscriptRevision: Int
    let text: String
    let language: String?
    let embedding: Data
    let embeddingFingerprint: String

    func matches(
        correctionID: UUID,
        baseTranscriptRevision: Int,
        text: String,
        language: String?
    ) -> Bool {
        self.correctionID == correctionID
            && self.baseTranscriptRevision == baseTranscriptRevision
            && self.text == text
            && self.language == language
    }
}
