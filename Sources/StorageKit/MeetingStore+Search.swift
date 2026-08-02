import Accelerate
import Foundation
import GRDB
import PortavozCore

/// Immutable source identity carried from semantic batch selection through
/// publication. Storage revalidates every field before accepting a vector, so
/// a concurrent transcript replacement cannot attach stale derived data to a
/// reused segment identifier.
public struct SemanticEmbeddingCandidate: Equatable, Sendable {
    public let id: UUID
    public let meetingID: MeetingID
    public let transcriptRevision: Int
    public let text: String

    public init(
        id: UUID,
        meetingID: MeetingID,
        transcriptRevision: Int,
        text: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.transcriptRevision = transcriptRevision
        self.text = text
    }
}

/// Content-free outcome of a revision-fenced semantic batch publication.
public struct SemanticEmbeddingPublicationResult: Equatable, Sendable {
    public let publishedSegmentIDs: Set<UUID>
    public let skippedSegmentIDs: Set<UUID>

    public init(
        publishedSegmentIDs: Set<UUID>,
        skippedSegmentIDs: Set<UUID>
    ) {
        self.publishedSegmentIDs = publishedSegmentIDs
        self.skippedSegmentIDs = skippedSegmentIDs
    }

    public static let empty = SemanticEmbeddingPublicationResult(
        publishedSegmentIDs: [],
        skippedSegmentIDs: [])
}

/// Ordered citation identity emitted by a derived semantic-search engine.
///
/// The authoritative store resolves this value back to current transcript
/// evidence before an engine result may cross the semantic query port.
public struct SemanticSearchCandidateIdentity: Equatable, Hashable, Sendable {
    public let segmentID: UUID
    public let transcriptRevision: Int

    public init(
        segmentID: UUID,
        transcriptRevision: Int
    ) {
        self.segmentID = segmentID
        self.transcriptRevision = transcriptRevision
    }
}

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
                       meeting.transcriptRevision AS transcriptRevision,
                       snippet(segmentSearch, 0, '[', ']', '…', 12) AS snippet
                FROM segmentSearch
                JOIN segment ON segment.rowid = segmentSearch.rowid
                JOIN meeting ON meeting.id = segment.meetingID
                WHERE segmentSearch MATCH ?
                  AND segment.deletedAt IS NULL
                  AND meeting.deletedAt IS NULL
                  AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
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

    // MARK: - Semantic index (local RAG, M8)

    /// Whether the live library contains any row eligible for semantic search.
    /// Background maintenance uses this profile-free probe to avoid touching
    /// the model runtime for a genuinely empty corpus.
    public func hasSemanticCorpusRows() async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM segment
                        JOIN meeting ON meeting.id = segment.meetingID
                        WHERE segment.deletedAt IS NULL
                          AND meeting.deletedAt IS NULL
                          AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                        LIMIT 1
                    )
                    """) ?? false
        }
    }

    /// Whether live searchable rows are missing a vector compatible with the
    /// active model and vector schema. This probe is read-only so Library and
    /// Ask can expose exact-first readiness without owning maintenance.
    public func semanticIndexRequiresMaintenance(
        for profile: SemanticEmbeddingProfile
    ) async throws -> Bool {
        guard profile.isValid else {
            throw StorageError.invalidSemanticEmbedding("profile is invalid")
        }
        return try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM segment
                        JOIN meeting ON meeting.id = segment.meetingID
                        WHERE segment.deletedAt IS NULL
                          AND meeting.deletedAt IS NULL
                          AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                          AND (
                              segment.embedding IS NULL
                              OR segment.embeddingFingerprint IS NOT ?
                          )
                        LIMIT 1
                    )
                    """,
                arguments: [profile.fingerprint]) ?? false
        }
    }

    /// Resets incompatible derived vectors to the existing NULL replay cursor.
    /// Transcript, FTS, and other authoritative meeting state are untouched.
    @discardableResult
    public func invalidateSemanticEmbeddings(
        incompatibleWith profile: SemanticEmbeddingProfile
    ) async throws -> Int {
        guard profile.isValid else {
            throw StorageError.invalidSemanticEmbedding("profile is invalid")
        }
        return try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE segment
                    SET embedding = NULL, embeddingFingerprint = NULL
                    WHERE (embedding IS NOT NULL AND embeddingFingerprint IS NOT ?)
                       OR (embedding IS NULL AND embeddingFingerprint IS NOT NULL)
                    """,
                arguments: [profile.fingerprint])
            return db.changesCount
        }
    }

    /// Segments (live, non-tombstoned) that still need an embedding.
    public func segmentsNeedingEmbeddings(
        limit: Int = 512
    ) async throws -> [SemanticEmbeddingCandidate] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS id,
                           segment.meetingID AS meetingID,
                           meeting.transcriptRevision AS transcriptRevision,
                           segment.text AS text
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.embedding IS NULL AND segment.deletedAt IS NULL
                      AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                    ORDER BY segment.createdAt, segment.rowid
                    LIMIT ?
                    """,
                arguments: [limit])
            return try rows.map { row in
                SemanticEmbeddingCandidate(
                    id: try PersistedIdentity.required(
                        row["id"], table: "segment", column: "id"),
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"], table: "segment", column: "meetingID")),
                    transcriptRevision: row["transcriptRevision"],
                    text: row["text"])
            }
        }
    }

    /// Stores L2-normalized embeddings (Float32 LE blobs) only while every
    /// selected source identity is still current. Already-published,
    /// tombstoned, edited, or revision-superseded rows are idempotent no-ops.
    public func storeEmbeddings(
        _ embeddings: [UUID: [Float]],
        for candidates: [SemanticEmbeddingCandidate],
        profile: SemanticEmbeddingProfile
    ) async throws -> SemanticEmbeddingPublicationResult {
        guard profile.isValid,
              Set(candidates.map(\.id)).count == candidates.count,
              Set(embeddings.keys) == Set(candidates.map(\.id)),
              candidates.allSatisfy({ $0.transcriptRevision >= 0 }),
              embeddings.values.allSatisfy({ vector in
                  vector.isEmpty
                      || (vector.count == profile.vectorDimension
                          && vector.allSatisfy(\.isFinite))
              })
        else {
            throw StorageError.invalidSemanticEmbedding(
                "profile and finite vectors must exactly match unique candidates")
        }
        guard !candidates.isEmpty else { return .empty }

        return try await database.write { db in
            var published: Set<UUID> = []
            published.reserveCapacity(candidates.count)
            for candidate in candidates {
                guard let vector = embeddings[candidate.id] else {
                    throw StorageError.invalidSemanticEmbedding(
                        "every candidate must have one vector")
                }
                try db.execute(
                    sql: """
                        UPDATE segment
                        SET embedding = ?, embeddingFingerprint = ?
                        WHERE id = ?
                          AND meetingID = ?
                          AND text = ?
                          AND deletedAt IS NULL
                          AND embedding IS NULL
                          AND embeddingFingerprint IS NULL
                          AND EXISTS (
                              SELECT 1 FROM meeting
                              WHERE meeting.id = segment.meetingID
                                AND meeting.deletedAt IS NULL
                                AND meeting.transcriptRevision = ?
                          )
                          AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                        """,
                    arguments: [
                        Self.blob(from: vector),
                        profile.fingerprint,
                        candidate.id.uuidString,
                        candidate.meetingID.rawValue.uuidString,
                        candidate.text,
                        candidate.transcriptRevision
                    ])
                if db.changesCount == 1 {
                    published.insert(candidate.id)
                }
            }
            return SemanticEmbeddingPublicationResult(
                publishedSegmentIDs: published,
                skippedSegmentIDs: Set(candidates.map(\.id)).subtracting(published))
        }
    }

    /// Exact cosine top-k over every embedded segment. Embeddings are
    /// normalized at write time, so cosine is a dot product. Rows stream from
    /// SQLite, BLOB bytes are scored without a Float-array copy, and only the
    /// bounded best candidates survive (D83).
    public func searchSemantic(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int = 8
    ) async throws -> [SearchHit] {
        guard profile.isValid,
              limit > 0,
              query.count == profile.vectorDimension,
              query.allSatisfy(\.isFinite)
        else { return [] }
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
                    WHERE segment.embedding IS NOT NULL
                      AND segment.embeddingFingerprint = ?
                      AND segment.deletedAt IS NULL
                      AND segment.meetingID NOT IN (
                          SELECT meeting.id FROM meeting WHERE meeting.deletedAt IS NOT NULL
                      )
                      AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                    ORDER BY segment.rowid ASC
                    """,
                arguments: [profile.fingerprint])
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

    /// Resolves ordered derived-index identities through current authoritative
    /// transcript rows. Missing, deleted, duplicate, invalid-revision, or stale
    /// candidates are omitted without allowing later ranks to exceed `limit`.
    public func projectSemanticSearchCandidates(
        _ candidates: [SemanticSearchCandidateIdentity],
        limit: Int
    ) async throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        var seen: Set<UUID> = []
        var ordered: [SemanticSearchCandidateIdentity] = []
        ordered.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates.prefix(limit) where candidate.transcriptRevision >= 0 {
            guard seen.insert(candidate.segmentID).inserted else { continue }
            ordered.append(candidate)
        }
        guard !ordered.isEmpty else { return [] }
        let orderedCandidates = ordered

        return try await database.read { db in
            let segmentKeys = orderedCandidates.map { $0.segmentID.uuidString }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT segment.id AS segmentID,
                           segment.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           segment.text AS text,
                           meeting.title AS title,
                           meeting.transcriptRevision AS transcriptRevision
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID
                        AND meeting.deletedAt IS NULL
                    WHERE segment.id IN (\(databaseQuestionMarks(count: segmentKeys.count)))
                      AND segment.deletedAt IS NULL
                      AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
                    """,
                arguments: StatementArguments(segmentKeys))
            var current: [UUID: SearchHit] = [:]
            current.reserveCapacity(rows.count)
            for row in rows {
                let segmentID = try PersistedIdentity.required(
                    row["segmentID"], table: "segment", column: "id")
                current[segmentID] = SearchHit(
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"], table: "segment", column: "meetingID")),
                    meetingTitle: row["title"],
                    segmentID: segmentID,
                    text: row["text"],
                    snippet: row["text"],
                    startTime: row["startTime"],
                    transcriptRevision: row["transcriptRevision"])
            }
            return orderedCandidates.compactMap { candidate in
                guard let hit = current[candidate.segmentID],
                      hit.transcriptRevision == candidate.transcriptRevision
                else { return nil }
                return hit
            }
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
                           meeting.title AS title,
                           meeting.transcriptRevision AS transcriptRevision
                    FROM segment
                    JOIN meeting ON meeting.id = segment.meetingID AND meeting.deletedAt IS NULL
                    WHERE segment.rowid IN (\(databaseQuestionMarks(count: chunk.count)))
                      AND segment.deletedAt IS NULL
                      AND \(Self.acceptedSegmentHasNoActiveCorrectionSQL)
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
                    startTime: row["startTime"],
                    transcriptRevision: row["transcriptRevision"])
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
