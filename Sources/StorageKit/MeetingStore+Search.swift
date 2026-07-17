import Accelerate
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
        guard limit > 0 else { return [] }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT segment.id AS segmentID,
                       segment.meetingID AS meetingID,
                       segment.startTime AS startTime,
                       segment.text AS text,
                       meeting.title AS title,
                       snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet
                FROM segmentSearch
                JOIN segment ON segment.rowid = segmentSearch.rowid
                JOIN meeting ON meeting.id = segment.meetingID
                WHERE segmentSearch MATCH ?
                  AND segment.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                -- FTS5's hidden rank column defaults to bm25(), but unlike
                -- calling bm25() here it can abandon scoring after LIMIT.
                ORDER BY rank
                LIMIT ?
                """,
            arguments: [match, limit])
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

    /// Exact cosine top-k over every embedded segment. Embeddings are
    /// normalized at write time, so cosine is a dot product. Rows stream from
    /// SQLite, BLOB bytes are scored without a Float-array copy, and only the
    /// bounded best candidates survive (D83).
    public func searchSemantic(_ query: [Float], limit: Int = 8) async throws -> [SearchHit] {
        guard limit > 0, !query.isEmpty else { return [] }
        let (expectedBytes, overflow) = query.count.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size)
        guard !overflow else { return [] }
        return try await database.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT segment.embedding AS embedding,
                           segment.rowid AS rowID
                    FROM segment
                    WHERE segment.embedding IS NOT NULL AND segment.deletedAt IS NULL
                      AND segment.meetingID NOT IN (
                          SELECT meeting.id FROM meeting WHERE meeting.deletedAt IS NOT NULL
                      )
                    ORDER BY segment.rowid ASC
                    """)
            var candidates: [SemanticCandidate] = []
            candidates.reserveCapacity(min(limit, 64))
            var traversalOrder = 0

            try query.withUnsafeBufferPointer { queryBuffer in
                while let row = try rows.next() {
                    let order = traversalOrder
                    traversalOrder += 1
                    let score = try row.withUnsafeData(atIndex: 0) { blob -> Float? in
                        guard let blob else { return nil }
                        return Self.semanticDotProduct(
                            blob, query: queryBuffer, expectedBytes: expectedBytes)
                    }
                    guard let score else { continue }
                    if candidates.count == limit,
                       let worst = candidates.last,
                       !SemanticCandidate.isBetter(score: score, order: order, than: worst) {
                        continue
                    }
                    let candidate = SemanticCandidate(
                        score: score,
                        order: order,
                        rowID: row["rowID"])
                    let insertionIndex = candidates.firstIndex {
                        candidate.isBetter(than: $0)
                    } ?? candidates.endIndex
                    candidates.insert(candidate, at: insertionIndex)
                    if candidates.count > limit { candidates.removeLast() }
                }
            }
            return try Self.semanticHits(in: db, candidates: candidates)
        }
    }

    private static func semanticDotProduct(
        _ blob: Data,
        query: UnsafeBufferPointer<Float>,
        expectedBytes: Int
    ) -> Float? {
        guard blob.count == expectedBytes else { return nil }
        return blob.withUnsafeBytes { rawBuffer -> Float? in
            guard let vectorAddress = rawBuffer.baseAddress,
                  let queryAddress = query.baseAddress
            else { return nil }
            var result: Float = 0
            if Int(bitPattern: vectorAddress).isMultiple(of: MemoryLayout<Float>.alignment) {
                vDSP_dotpr(
                    vectorAddress.assumingMemoryBound(to: Float.self), 1,
                    queryAddress, 1,
                    &result, vDSP_Length(query.count))
            } else {
                for index in query.indices {
                    let value = rawBuffer.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Float>.size,
                        as: Float.self)
                    result += value * query[index]
                }
            }
            return result.isFinite ? result : nil
        }
    }

    private static func semanticHits(
        in database: Database,
        candidates: [SemanticCandidate]
    ) throws -> [SearchHit] {
        guard !candidates.isEmpty else { return [] }
        let rowIDs = candidates.map(\.rowID)
        var hitsByRowID: [Int64: SearchHit] = [:]
        hitsByRowID.reserveCapacity(rowIDs.count)
        for lowerBound in stride(from: 0, to: rowIDs.count, by: 500) {
            let upperBound = min(lowerBound + 500, rowIDs.count)
            let chunk = Array(rowIDs[lowerBound..<upperBound])
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT segment.rowid AS rowID,
                           segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           segment.text AS text,
                           meeting.title AS title
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.rowid IN (\(databaseQuestionMarks(count: chunk.count)))
                      AND segment.deletedAt IS NULL
                    """,
                arguments: StatementArguments(chunk))
            for row in rows {
                hitsByRowID[row["rowID"]] = SearchHit(
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"], table: "segment", column: "meetingID")),
                    meetingTitle: row["title"],
                    segmentID: try PersistedIdentity.required(
                        row["segmentID"], table: "segment", column: "id"),
                    text: row["text"],
                    snippet: row["text"],
                    startTime: row["startTime"])
            }
        }
        return try candidates.map { candidate in
            guard let hit = hitsByRowID[candidate.rowID] else {
                throw StorageError.invalidPersistedValue(
                    table: "segment", column: "rowid", value: String(candidate.rowID))
            }
            return hit
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

private struct SemanticCandidate {
    let score: Float
    let order: Int
    let rowID: Int64

    func isBetter(than other: SemanticCandidate) -> Bool {
        Self.isBetter(score: score, order: order, than: other)
    }

    static func isBetter(score: Float, order: Int, than other: SemanticCandidate) -> Bool {
        score > other.score || (score == other.score && order < other.order)
    }
}
