import Foundation
import GRDB
import PortavozCore

// Full-text (FTS5) and semantic (local RAG) search. Split out of
// `MeetingStore.swift` so the core type stays small.
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
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segment.id AS segmentID,
                       segment.meetingID AS meetingID,
                       segment.startTime AS startTime,
                       meeting.title AS title,
                       snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet
                FROM segmentSearch
                JOIN segment ON segment.rowid = segmentSearch.rowid
                JOIN meeting ON meeting.id = segment.meetingID
                WHERE segmentSearch MATCH ?
                  AND segment.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                ORDER BY bm25(segmentSearch)
                LIMIT ?
                """,
            arguments: [match, limit])
        return try rows.map { row in
            SearchHit(
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "segment", column: "meetingID")),
                meetingTitle: row["title"],
                segmentID: try PersistedIdentity.required(
                    row["segmentID"], table: "segment", column: "id"),
                snippet: row["snippet"],
                startTime: row["startTime"])
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

    // MARK: - Semantic index (local RAG, M8)

    /// Segments (live, non-tombstoned) that still need an embedding.
    public func segmentsNeedingEmbeddings(limit: Int = 512) async throws -> [(id: UUID, text: String)] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS id, segment.text AS text
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.embedding IS NULL AND segment.deletedAt IS NULL
                    ORDER BY segment.createdAt
                    LIMIT ?
                    """,
                arguments: [limit])
            return try rows.map { row in
                let id = try PersistedIdentity.required(
                    row["id"], table: "segment", column: "id")
                return (id, row["text"])
            }
        }
    }

    /// Stores L2-normalized embeddings (Float32 LE blobs) per segment.
    public func storeEmbeddings(_ embeddings: [UUID: [Float]]) async throws {
        try await database.write { db in
            for (id, vector) in embeddings {
                try db.execute(
                    sql: "UPDATE segment SET embedding = ? WHERE id = ?",
                    arguments: [Self.blob(from: vector), id.uuidString])
            }
        }
    }

    /// Brute-force cosine top-k over every embedded segment. Embeddings
    /// are normalized at write time, so cosine is a dot product. At
    /// meeting scale (thousands of rows) this is milliseconds; sqlite-vec
    /// earns its place when it isn't (D19).
    public func searchSemantic(_ query: [Float], limit: Int = 8) async throws -> [SearchHit] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           segment.text AS text,
                           segment.embedding AS embedding,
                           meeting.title AS title
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.embedding IS NOT NULL AND segment.deletedAt IS NULL
                    """)
            let scored: [(Float, SearchHit)] = try rows.compactMap { row in
                guard let blob = row["embedding"] as Data? else { return nil }
                let vector = Self.floats(from: blob)
                guard vector.count == query.count else { return nil }
                var dot: Float = 0
                for index in 0..<vector.count { dot += vector[index] * query[index] }
                let hit = SearchHit(
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"], table: "segment", column: "meetingID")),
                    meetingTitle: row["title"],
                    segmentID: try PersistedIdentity.required(
                        row["segmentID"], table: "segment", column: "id"),
                    snippet: row["text"],
                    startTime: row["startTime"])
                return (dot, hit)
            }
            return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        }
    }

    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
