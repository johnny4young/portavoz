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
        let hasStructuralProjection = try database.tableExists(
            "transcriptStructuralSearchRow")
        let existingStructuralEmbeddings = try preservedStructuralEmbeddings(
            meetingID: meetingID,
            hasStructuralProjection: hasStructuralProjection,
            in: database)
        // v33 invokes this same rebuild before v36 has created the sparse
        // lineage table. Keep that historical migration independently
        // runnable; v36 repeats the rebuild immediately after creating it.
        let hasCorrectionState = try database.tableExists(
            "transcriptCorrectionSearchState")
        try clearTranscriptCorrectionSearchProjection(
            meetingKey: key,
            hasCorrectionState: hasCorrectionState,
            hasStructuralProjection: hasStructuralProjection,
            in: database)
        guard let revision = try Int.fetchOne(
            database,
            sql: "SELECT transcriptRevision FROM meeting WHERE id = ?",
            arguments: [key])
        else { return }
        let history = try fetchTranscriptCorrectionHistory(
            meetingID: meetingID,
            in: database)
        try refreshCorrectionSearchState(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: revision,
            meetingKey: key,
            hasCorrectionState: hasCorrectionState,
            in: database)
        try refreshCorrectedTextProjection(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: revision,
            hasEmbeddingColumns: hasEmbeddingColumns,
            existingEmbeddings: existingEmbeddings,
            in: database)
        guard hasStructuralProjection else { return }
        try refreshStructuralSearchProjection(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: revision,
            meetingKey: key,
            existingEmbeddings: existingStructuralEmbeddings,
            in: database)
    }

    private static func clearTranscriptCorrectionSearchProjection(
        meetingKey: String,
        hasCorrectionState: Bool,
        hasStructuralProjection: Bool,
        in database: Database
    ) throws {
        if hasCorrectionState {
            try database.execute(
                sql: "DELETE FROM transcriptCorrectionSearchState WHERE meetingID = ?",
                arguments: [meetingKey])
        }
        try database.execute(
            sql: "DELETE FROM segmentCorrectedText WHERE meetingID = ?",
            arguments: [meetingKey])
        if hasStructuralProjection {
            try database.execute(
                sql: "DELETE FROM transcriptStructuralSearchRow WHERE meetingID = ?",
                arguments: [meetingKey])
        }
    }

    private static func refreshCorrectionSearchState(
        history: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        meetingKey: String,
        hasCorrectionState: Bool,
        in database: Database
    ) throws {
        guard hasCorrectionState else { return }
        let correctionRevision = try TranscriptCorrectionRevision.current(
            meetingID: meetingID,
            baseTranscriptRevision: baseTranscriptRevision,
            history: history)
        guard !correctionRevision.isAccepted else { return }
        try database.execute(
            sql: """
                INSERT INTO transcriptCorrectionSearchState
                    (meetingID, baseTranscriptRevision, correctionRevision)
                VALUES (?, ?, ?)
                """,
            arguments: [
                meetingKey,
                baseTranscriptRevision,
                correctionRevision.rawValue
            ])
    }

    private static func refreshCorrectedTextProjection(
        history: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        hasEmbeddingColumns: Bool,
        existingEmbeddings: [UUID: PreservedCorrectedEmbedding],
        in database: Database
    ) throws {
        let meetingKey = meetingID.rawValue.uuidString
        let replacements = SegmentCorrectedTextProjection.activeReplacements(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: baseTranscriptRevision)
        for replacement in replacements {
            let preserved = existingEmbeddings[replacement.segmentID].flatMap { existing in
                existing.matches(
                    correctionID: replacement.correctionID,
                    baseTranscriptRevision: baseTranscriptRevision,
                    text: replacement.text,
                    language: replacement.language) ? existing : nil
            }
            // INSERT…SELECT keeps the row out when the segment is tombstoned:
            // corrected text must never resurrect an unavailable source line.
            try insertCorrectedText(
                replacement,
                baseTranscriptRevision: baseTranscriptRevision,
                meetingKey: meetingKey,
                hasEmbeddingColumns: hasEmbeddingColumns,
                preservedEmbedding: preserved,
                in: database)
        }
    }

    private static func refreshStructuralSearchProjection(
        history: [TranscriptCorrectionEvent],
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        meetingKey: String,
        existingEmbeddings: [UUID: PreservedStructuralEmbedding],
        in database: Database
    ) throws {
        let segmentRecords = try SegmentRecord.fetchAll(
            database,
            sql: """
                SELECT * FROM segment
                WHERE meetingID = ?
                  AND deletedAt IS NULL
                ORDER BY startTime, endTime, id
                """,
            arguments: [meetingKey])
        let segments = try segmentRecords.map { try $0.segment }
        let structuralRows = TranscriptStructuralSearchProjection.activeRows(
            history: history,
            meetingID: meetingID,
            baseTranscriptRevision: baseTranscriptRevision,
            segments: segments)
        for row in structuralRows {
            let preserved = existingEmbeddings[row.resultID].flatMap { existing in
                existing.matches(
                    row,
                    baseTranscriptRevision: baseTranscriptRevision) ? existing : nil
            }
            try insertStructuralSearchRow(
                row,
                baseTranscriptRevision: baseTranscriptRevision,
                meetingKey: meetingKey,
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

    private static func preservedStructuralEmbeddings(
        meetingID: MeetingID,
        hasStructuralProjection: Bool,
        in database: Database
    ) throws -> [UUID: PreservedStructuralEmbedding] {
        guard hasStructuralProjection else { return [:] }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT resultID, correctionID, baseTranscriptRevision, kind,
                       text, language, startTime, endTime,
                       embedding, embeddingFingerprint
                FROM transcriptStructuralSearchRow
                WHERE meetingID = ?
                  AND embedding IS NOT NULL
                  AND embeddingFingerprint IS NOT NULL
                """,
            arguments: [meetingID.rawValue.uuidString])
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            let resultID = try PersistedIdentity.required(
                row["resultID"],
                table: "transcriptStructuralSearchRow",
                column: "resultID")
            return (resultID, PreservedStructuralEmbedding(
                correctionID: try PersistedIdentity.required(
                    row["correctionID"],
                    table: "transcriptStructuralSearchRow",
                    column: "correctionID"),
                baseTranscriptRevision: row["baseTranscriptRevision"],
                kind: row["kind"],
                text: row["text"],
                language: row["language"],
                startTime: row["startTime"],
                endTime: row["endTime"],
                embedding: row["embedding"],
                embeddingFingerprint: row["embeddingFingerprint"]))
        })
    }

    private static func insertStructuralSearchRow(
        _ row: TranscriptStructuralSearchRow,
        baseTranscriptRevision: Int,
        meetingKey: String,
        preservedEmbedding: PreservedStructuralEmbedding?,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO transcriptStructuralSearchRow
                    (resultID, meetingID, correctionID, baseTranscriptRevision,
                     kind, text, language, startTime, endTime, updatedAt,
                     embedding, embeddingFingerprint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                row.resultID.uuidString,
                meetingKey,
                row.correctionID.uuidString,
                baseTranscriptRevision,
                row.kind.rawValue,
                row.text,
                row.language,
                row.startTime,
                row.endTime,
                row.updatedAt,
                preservedEmbedding?.embedding,
                preservedEmbedding?.embeddingFingerprint
            ])
        for (ordinal, sourceID) in row.sourceSegmentIDs.enumerated() {
            try database.execute(
                sql: """
                    INSERT INTO transcriptStructuralSearchSource
                        (resultID, ordinal, segmentID)
                    VALUES (?, ?, ?)
                    """,
                arguments: [row.resultID.uuidString, ordinal, sourceID.uuidString])
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

private struct PreservedStructuralEmbedding {
    let correctionID: UUID
    let baseTranscriptRevision: Int
    let kind: String
    let text: String
    let language: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let embedding: Data
    let embeddingFingerprint: String

    func matches(
        _ row: TranscriptStructuralSearchRow,
        baseTranscriptRevision: Int
    ) -> Bool {
        correctionID == row.correctionID
            && self.baseTranscriptRevision == baseTranscriptRevision
            && kind == row.kind.rawValue
            && text == row.text
            && language == row.language
            && startTime == row.startTime
            && endTime == row.endTime
    }
}
