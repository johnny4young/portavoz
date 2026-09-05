import Foundation
import GRDB
import PortavozCore

// Full-text (FTS5) search. Split out of MeetingStore.swift so the core type stays small.
extension MeetingStore {
    // MARK: - Full-text search

    /// `requireAll: false` turns the tokens into an OR query — what a
    /// natural-language QUESTION needs (AND of every question word almost
    /// never matches a transcript).
    public func search(
        _ query: String,
        meetingID: MeetingID? = nil,
        limit: Int = 20,
        requireAll: Bool = true
    ) async throws -> [SearchHit] {
        let match = Self.ftsQuery(from: query, requireAll: requireAll)
        guard !match.isEmpty else { return [] }
        return try await database.read { db in
            try Self.fetchSearch(
                in: db,
                match: match,
                meetingID: meetingID,
                limit: limit)
        }
    }

    static func fetchSearch(
        in database: Database,
        match: String,
        meetingID: MeetingID? = nil,
        limit: Int
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        // Three lanes, one retrieval contract: accepted text for segments
        // without an active text-affecting correction, corrected text
        // (T28b/D313) under accepted identity, and structural split/merge text
        // (T28/D334) under stable result identity with accepted provenance.
        // Active targets can never also serve from the accepted lane.
        let rows: [Row]
        if let meetingID {
            let key = meetingID.rawValue.uuidString
            rows = try Row.fetchAll(
                database,
                sql: CorrectionAwareSearchSQL.meetingQuery,
                arguments: [
                    match, key, limit,
                    match, key, limit,
                    match, key, limit,
                    limit
                ])
        } else {
            rows = try Row.fetchAll(
                database,
                sql: CorrectionAwareSearchSQL.libraryQuery,
                arguments: [match, limit, match, limit, match, limit, limit])
        }
        return try Self.searchHits(from: rows)
    }

    private static func searchHits(from rows: [Row]) throws -> [SearchHit] {
        try rows.map { row in
            let sourceIDs = try sourceSegmentIDs(
                row["sourceSegmentIDs"],
                resultID: row["segmentID"])
            return SearchHit(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "segment", column: "meetingID")),
                meetingTitle: row["title"],
                resultID: try PersistedIdentity.required(
                    row["segmentID"], table: "segment", column: "id"),
                sourceSegmentIDs: sourceIDs,
                text: row["text"],
                snippet: row["snippet"],
                startTime: row["startTime"],
                transcriptRevision: row["transcriptRevision"])
        }
    }

    static func sourceSegmentIDs(
        _ persisted: String?,
        resultID: String?
    ) throws -> [UUID] {
        let sourceValues = persisted?.split(separator: ",").map(String.init) ?? []
        guard !sourceValues.isEmpty else {
            throw StorageError.invalidPersistedValue(
                table: "transcriptStructuralSearchSource",
                column: "segmentID",
                value: resultID ?? "missing")
        }
        let sources = try sourceValues.map {
            try PersistedIdentity.required(
                $0,
                table: "transcriptStructuralSearchSource",
                column: "segmentID")
        }
        guard Set(sources).count == sources.count else {
            throw StorageError.invalidPersistedValue(
                table: "transcriptStructuralSearchSource",
                column: "segmentID",
                value: persisted ?? "missing")
        }
        return sources
    }

    /// User text → safe FTS5 MATCH expression: every token quoted,
    /// embedded quotes doubled, so no input can break the query syntax.
    /// Tokens are ANDed (exact search) or ORed (question retrieval).
    static func ftsQuery(from text: String, requireAll: Bool = true) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: requireAll ? " " : " OR ")
    }

}

private enum CorrectionAwareSearchSQL {
    static let libraryQuery = query(
        acceptedScope: "",
        correctedScope: "",
        structuralScope: "")

    static let meetingQuery = query(
        acceptedScope: "AND segment.meetingID = ?",
        correctedScope: "AND corrected.meetingID = ?",
        structuralScope: "AND structural.meetingID = ?")

    private static func query(
        acceptedScope: String,
        correctedScope: String,
        structuralScope: String
    ) -> String {
        """
        \(acceptedQuery(scope: acceptedScope))
        UNION ALL
        \(correctedQuery(scope: correctedScope))
        UNION ALL
        \(structuralQuery(scope: structuralScope))
        ORDER BY searchRank
        LIMIT ?
        """
    }

    private static func acceptedQuery(scope: String) -> String {
        """
        SELECT * FROM (
            SELECT segment.id AS segmentID,
                   segment.meetingID AS meetingID,
                   segment.startTime AS startTime,
                   segment.text AS text,
                   meeting.title AS title,
                   meeting.transcriptRevision AS transcriptRevision,
                   segment.id AS sourceSegmentIDs,
                   snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet,
                   rank AS searchRank
            FROM segmentSearch
            JOIN segment ON segment.rowid = segmentSearch.rowid
            JOIN meeting ON meeting.id = segment.meetingID
            WHERE segmentSearch MATCH ?
              \(scope)
              AND segment.deletedAt IS NULL
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.acceptedSegmentHasNoActiveTextCorrectionSQL)
            -- FTS5's hidden rank column defaults to bm25(), but unlike
            -- calling bm25() here it can abandon scoring after LIMIT.
            ORDER BY rank
            LIMIT ?
        )
        """
    }

    private static func correctedQuery(scope: String) -> String {
        """
        SELECT * FROM (
            SELECT segment.id AS segmentID,
                   segment.meetingID AS meetingID,
                   segment.startTime AS startTime,
                   corrected.text AS text,
                   meeting.title AS title,
                   meeting.transcriptRevision AS transcriptRevision,
                   segment.id AS sourceSegmentIDs,
                   snippet(segmentCorrectedSearch, 0, '[', ']', '…', 12) AS snippet,
                   rank AS searchRank
            FROM segmentCorrectedSearch
            JOIN segmentCorrectedText AS corrected
              ON corrected.rowid = segmentCorrectedSearch.rowid
            JOIN segment ON segment.id = corrected.segmentID
            JOIN meeting ON meeting.id = corrected.meetingID
            WHERE segmentCorrectedSearch MATCH ?
              \(scope)
              AND corrected.baseTranscriptRevision = meeting.transcriptRevision
              AND segment.deletedAt IS NULL
              AND meeting.deletedAt IS NULL
            ORDER BY rank
            LIMIT ?
        )
        """
    }

    private static func structuralQuery(scope: String) -> String {
        """
        SELECT * FROM (
            SELECT structural.resultID AS segmentID,
                   structural.meetingID AS meetingID,
                   structural.startTime AS startTime,
                   structural.text AS text,
                   meeting.title AS title,
                   meeting.transcriptRevision AS transcriptRevision,
                   (
                       SELECT GROUP_CONCAT(orderedSource.segmentID, ',')
                       FROM (
                           SELECT source.segmentID
                           FROM transcriptStructuralSearchSource AS source
                           WHERE source.resultID = structural.resultID
                           ORDER BY source.ordinal
                       ) AS orderedSource
                   ) AS sourceSegmentIDs,
                   snippet(
                       transcriptStructuralSearch, 0, '[', ']', '…', 12
                   ) AS snippet,
                   rank AS searchRank
            FROM transcriptStructuralSearch
            JOIN transcriptStructuralSearchRow AS structural
              ON structural.rowid = transcriptStructuralSearch.rowid
            JOIN meeting ON meeting.id = structural.meetingID
            JOIN transcriptCorrectionSearchState AS correctionState
              ON correctionState.meetingID = structural.meetingID
            JOIN transcriptCorrection AS correction
              ON correction.id = structural.correctionID
            WHERE transcriptStructuralSearch MATCH ?
              \(scope)
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.currentStructuralTextSourceSQL)
            ORDER BY rank
            LIMIT ?
        )
        """
    }
}
