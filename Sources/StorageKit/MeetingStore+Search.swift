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
        _ query: String, limit: Int = 20, requireAll: Bool = true
    ) async throws -> [SearchHit] {
        let match = Self.ftsQuery(from: query, requireAll: requireAll)
        guard !match.isEmpty else { return [] }
        return try await database.read { db in
            try Self.fetchSearch(in: db, match: match, limit: limit)
        }
    }

    static func fetchSearch(
        in database: Database,
        match: String,
        limit: Int
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        // Two lanes, one identity: accepted text for segments without an
        // active text-affecting correction, corrected text (T28b/D313) for
        // segments whose active replaceText projected a row. A segment can
        // never serve from both — the projection row only exists when the
        // predicate excludes the accepted text.
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT * FROM (
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           segment.text AS text,
                           meeting.title AS title,
                           meeting.transcriptRevision AS transcriptRevision,
                           snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet,
                           rank AS searchRank
                    FROM segmentSearch
                    JOIN segment ON segment.rowid = segmentSearch.rowid
                    JOIN meeting ON meeting.id = segment.meetingID
                    WHERE segmentSearch MATCH ?
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                      AND \(Self.acceptedSegmentHasNoActiveTextCorrectionSQL)
                    -- FTS5's hidden rank column defaults to bm25(), but unlike
                    -- calling bm25() here it can abandon scoring after LIMIT.
                    ORDER BY rank
                    LIMIT ?
                )
                UNION ALL
                SELECT * FROM (
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           corrected.text AS text,
                           meeting.title AS title,
                           meeting.transcriptRevision AS transcriptRevision,
                           snippet(segmentCorrectedSearch, 0, '[', ']', '…', 12) AS snippet,
                           rank AS searchRank
                    FROM segmentCorrectedSearch
                    JOIN segmentCorrectedText AS corrected
                      ON corrected.rowid = segmentCorrectedSearch.rowid
                    JOIN segment ON segment.id = corrected.segmentID
                    JOIN meeting ON meeting.id = corrected.meetingID
                    WHERE segmentCorrectedSearch MATCH ?
                      AND corrected.baseTranscriptRevision = meeting.transcriptRevision
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                    ORDER BY rank
                    LIMIT ?
                )
                ORDER BY searchRank
                LIMIT ?
                """,
            arguments: [match, limit, match, limit, limit])
        return try Self.searchHits(from: rows)
    }

    private static func searchHits(from rows: [Row]) throws -> [SearchHit] {
        try rows.map { row in
            SearchHit(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "segment", column: "meetingID")),
                meetingTitle: row["title"],
                segmentID: try PersistedIdentity.required(
                    row["segmentID"], table: "segment", column: "id"),
                text: row["text"],
                snippet: row["snippet"],
                startTime: row["startTime"],
                transcriptRevision: row["transcriptRevision"])
        }
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
