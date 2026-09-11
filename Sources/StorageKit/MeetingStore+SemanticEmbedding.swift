import Foundation
import GRDB
import PortavozCore

/// Immutable source identity carried from semantic batch selection through
/// publication. Storage revalidates every field before accepting a vector, so
/// a concurrent transcript replacement cannot attach stale derived data to a
/// reused retrieval-result identifier.
public struct SemanticEmbeddingCandidate: Equatable, Sendable {
    public enum Source: Equatable, Hashable, Sendable {
        case accepted
        case corrected(correctionID: UUID)
        case structural(correctionID: UUID)
    }

    public let id: UUID
    public let meetingID: MeetingID
    public let transcriptRevision: Int
    public let text: String
    public let source: Source

    public init(
        id: UUID,
        meetingID: MeetingID,
        transcriptRevision: Int,
        text: String,
        source: Source = .accepted
    ) {
        self.id = id
        self.meetingID = meetingID
        self.transcriptRevision = transcriptRevision
        self.text = text
        self.source = source
    }
}

/// Content-free outcome of a revision-fenced semantic batch publication.
/// Existing property names are source-compatible; each UUID is a retrieval
/// result identity and may identify an accepted segment or a structural result.
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

// Semantic corpus maintenance and revision-fenced vector publication.
extension MeetingStore {
    static let currentCorrectedTextSourceSQL = """
        corrected.baseTranscriptRevision = meeting.transcriptRevision
        AND correctionState.baseTranscriptRevision = meeting.transcriptRevision
        AND correction.meetingID = corrected.meetingID
        AND correction.baseTranscriptRevision = meeting.transcriptRevision
        AND correction.kind = 'replaceText'
        AND correction.deletedAt IS NULL
        AND EXISTS (
            SELECT 1
            FROM transcriptCorrectionTarget AS correctionTarget
            WHERE correctionTarget.correctionID = correction.id
              AND correctionTarget.segmentID = segment.id
        )
        AND NOT EXISTS (
            SELECT 1
            FROM transcriptCorrection AS successor
            WHERE successor.supersedesCorrectionID = correction.id
        )
        AND NOT EXISTS (
            SELECT 1
            FROM transcriptCorrectionTarget AS otherTarget
            JOIN transcriptCorrection AS otherCorrection
              ON otherCorrection.id = otherTarget.correctionID
            WHERE otherTarget.segmentID = segment.id
              AND otherCorrection.meetingID = segment.meetingID
              AND otherCorrection.baseTranscriptRevision = meeting.transcriptRevision
              AND otherCorrection.id <> correction.id
              AND otherCorrection.kind IN ('replaceText', 'split', 'merge', 'suppress')
              AND otherCorrection.deletedAt IS NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM transcriptCorrection AS otherSuccessor
                  WHERE otherSuccessor.supersedesCorrectionID = otherCorrection.id
              )
        )
        """

    static let currentStructuralTextSourceSQL = """
        structural.baseTranscriptRevision = meeting.transcriptRevision
        AND correctionState.baseTranscriptRevision = meeting.transcriptRevision
        AND correction.meetingID = structural.meetingID
        AND correction.baseTranscriptRevision = meeting.transcriptRevision
        AND correction.kind = structural.kind
        AND correction.kind IN ('split', 'merge')
        AND correction.deletedAt IS NULL
        AND NOT EXISTS (
            SELECT 1
            FROM transcriptCorrection AS successor
            WHERE successor.supersedesCorrectionID = correction.id
        )
        AND EXISTS (
            SELECT 1
            FROM transcriptStructuralSearchSource AS source
            WHERE source.resultID = structural.resultID
        )
        AND NOT EXISTS (
            SELECT 1
            FROM transcriptCorrectionTarget AS correctionTarget
            LEFT JOIN transcriptStructuralSearchSource AS source
              ON source.resultID = structural.resultID
             AND source.ordinal = correctionTarget.ordinal
             AND source.segmentID = correctionTarget.segmentID
            WHERE correctionTarget.correctionID = correction.id
              AND source.resultID IS NULL
        )
        AND NOT EXISTS (
            SELECT 1
            FROM transcriptStructuralSearchSource AS source
            LEFT JOIN transcriptCorrectionTarget AS correctionTarget
              ON correctionTarget.correctionID = correction.id
             AND correctionTarget.ordinal = source.ordinal
             AND correctionTarget.segmentID = source.segmentID
            LEFT JOIN segment
              ON segment.id = source.segmentID
            WHERE source.resultID = structural.resultID
              AND (
                  correctionTarget.correctionID IS NULL
                  OR segment.id IS NULL
                  OR segment.deletedAt IS NOT NULL
                  OR segment.meetingID <> structural.meetingID
              )
        )
        """

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
                          AND \(Self.acceptedSegmentHasNoActiveTextCorrectionSQL)
                        LIMIT 1
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM segmentCorrectedText AS corrected
                        JOIN segment ON segment.id = corrected.segmentID
                        JOIN meeting ON meeting.id = corrected.meetingID
                        JOIN transcriptCorrectionSearchState AS correctionState
                          ON correctionState.meetingID = corrected.meetingID
                        JOIN transcriptCorrection AS correction
                          ON correction.id = corrected.correctionID
                        WHERE segment.deletedAt IS NULL
                          AND meeting.deletedAt IS NULL
                          AND \(Self.currentCorrectedTextSourceSQL)
                        LIMIT 1
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM transcriptStructuralSearchRow AS structural
                        JOIN meeting ON meeting.id = structural.meetingID
                        JOIN transcriptCorrectionSearchState AS correctionState
                          ON correctionState.meetingID = structural.meetingID
                        JOIN transcriptCorrection AS correction
                          ON correction.id = structural.correctionID
                        WHERE meeting.deletedAt IS NULL
                          AND \(Self.currentStructuralTextSourceSQL)
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
                sql: SemanticEmbeddingSQL.requiresMaintenance,
                arguments: [
                    profile.fingerprint,
                    profile.fingerprint,
                    profile.fingerprint
                ]) ?? false
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
            var invalidated = 0
            try db.execute(
                sql: """
                    UPDATE segment
                    SET embedding = NULL, embeddingFingerprint = NULL
                    WHERE (embedding IS NOT NULL AND embeddingFingerprint IS NOT ?)
                       OR (embedding IS NULL AND embeddingFingerprint IS NOT NULL)
                    """,
                arguments: [profile.fingerprint])
            invalidated += db.changesCount
            try db.execute(
                sql: """
                    UPDATE transcriptStructuralSearchRow
                    SET embedding = NULL, embeddingFingerprint = NULL
                    WHERE (embedding IS NOT NULL AND embeddingFingerprint IS NOT ?)
                       OR (embedding IS NULL AND embeddingFingerprint IS NOT NULL)
                    """,
                arguments: [profile.fingerprint])
            invalidated += db.changesCount
            try db.execute(
                sql: """
                    UPDATE segmentCorrectedText
                    SET embedding = NULL, embeddingFingerprint = NULL
                    WHERE (embedding IS NOT NULL AND embeddingFingerprint IS NOT ?)
                       OR (embedding IS NULL AND embeddingFingerprint IS NOT NULL)
                    """,
                arguments: [profile.fingerprint])
            invalidated += db.changesCount
            return invalidated
        }
    }

    /// Segments (live, non-tombstoned) that still need an embedding.
    public func segmentsNeedingEmbeddings(
        limit: Int = 512
    ) async throws -> [SemanticEmbeddingCandidate] {
        guard limit > 0 else { return [] }
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: SemanticEmbeddingSQL.candidatesNeedingEmbeddings,
                arguments: [limit])
            return try Self.semanticEmbeddingCandidates(from: rows)
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
                let didPublish = try Self.storeEmbedding(
                    vector,
                    candidate: candidate,
                    profile: profile,
                    in: db)
                if didPublish {
                    published.insert(candidate.id)
                }
            }
            return SemanticEmbeddingPublicationResult(
                publishedSegmentIDs: published,
                skippedSegmentIDs: Set(candidates.map(\.id)).subtracting(published))
        }
    }

    private static func semanticEmbeddingCandidates(
        from rows: [Row]
    ) throws -> [SemanticEmbeddingCandidate] {
        try rows.map { row in
            let sourceName: String = row["source"]
            let source: SemanticEmbeddingCandidate.Source
            switch sourceName {
            case "accepted":
                source = .accepted
            case "corrected":
                source = .corrected(correctionID: try PersistedIdentity.required(
                    row["correctionID"],
                    table: "segmentCorrectedText",
                    column: "correctionID"))
            case "structural":
                source = .structural(correctionID: try PersistedIdentity.required(
                    row["correctionID"],
                    table: "transcriptStructuralSearchRow",
                    column: "correctionID"))
            default:
                throw StorageError.invalidPersistedValue(
                    table: "segmentCorrectedText",
                    column: "semanticSource",
                    value: sourceName)
            }
            return SemanticEmbeddingCandidate(
                id: try PersistedIdentity.required(
                    row["id"], table: "segment", column: "id"),
                meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                    row["meetingID"], table: "segment", column: "meetingID")),
                transcriptRevision: row["transcriptRevision"],
                text: row["text"],
                source: source)
        }
    }

    private static func storeEmbedding(
        _ vector: [Float],
        candidate: SemanticEmbeddingCandidate,
        profile: SemanticEmbeddingProfile,
        in database: Database
    ) throws -> Bool {
        switch candidate.source {
        case .accepted:
            try storeAcceptedEmbedding(
                vector,
                candidate: candidate,
                profile: profile,
                in: database)
        case .corrected(let correctionID):
            try storeCorrectedEmbedding(
                vector,
                candidate: candidate,
                correctionID: correctionID,
                profile: profile,
                in: database)
        case .structural(let correctionID):
            try storeStructuralEmbedding(
                vector,
                candidate: candidate,
                correctionID: correctionID,
                profile: profile,
                in: database)
        }
        return database.changesCount == 1
    }

    private static func storeAcceptedEmbedding(
        _ vector: [Float],
        candidate: SemanticEmbeddingCandidate,
        profile: SemanticEmbeddingProfile,
        in database: Database
    ) throws {
        try database.execute(
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
                  AND \(acceptedSegmentHasNoActiveTextCorrectionSQL)
                """,
            arguments: [
                blob(from: vector),
                profile.fingerprint,
                candidate.id.uuidString,
                candidate.meetingID.rawValue.uuidString,
                candidate.text,
                candidate.transcriptRevision
            ])
    }

    private static func storeCorrectedEmbedding(
        _ vector: [Float],
        candidate: SemanticEmbeddingCandidate,
        correctionID: UUID,
        profile: SemanticEmbeddingProfile,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE segmentCorrectedText
                SET embedding = ?, embeddingFingerprint = ?
                WHERE rowid IN (
                    SELECT corrected.rowid
                    FROM segmentCorrectedText AS corrected
                    JOIN segment ON segment.id = corrected.segmentID
                    JOIN meeting ON meeting.id = corrected.meetingID
                    JOIN transcriptCorrectionSearchState AS correctionState
                      ON correctionState.meetingID = corrected.meetingID
                    JOIN transcriptCorrection AS correction
                      ON correction.id = corrected.correctionID
                    WHERE corrected.segmentID = ?
                      AND corrected.meetingID = ?
                      AND corrected.correctionID = ?
                      AND corrected.baseTranscriptRevision = ?
                      AND corrected.text = ?
                      AND corrected.embedding IS NULL
                      AND corrected.embeddingFingerprint IS NULL
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                      AND \(currentCorrectedTextSourceSQL)
                )
                """,
            arguments: [
                blob(from: vector),
                profile.fingerprint,
                candidate.id.uuidString,
                candidate.meetingID.rawValue.uuidString,
                correctionID.uuidString,
                candidate.transcriptRevision,
                candidate.text
            ])
    }

    private static func storeStructuralEmbedding(
        _ vector: [Float],
        candidate: SemanticEmbeddingCandidate,
        correctionID: UUID,
        profile: SemanticEmbeddingProfile,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE transcriptStructuralSearchRow
                SET embedding = ?, embeddingFingerprint = ?
                WHERE rowid IN (
                    SELECT structural.rowid
                    FROM transcriptStructuralSearchRow AS structural
                    JOIN meeting ON meeting.id = structural.meetingID
                    JOIN transcriptCorrectionSearchState AS correctionState
                      ON correctionState.meetingID = structural.meetingID
                    JOIN transcriptCorrection AS correction
                      ON correction.id = structural.correctionID
                    WHERE structural.resultID = ?
                      AND structural.meetingID = ?
                      AND structural.correctionID = ?
                      AND structural.baseTranscriptRevision = ?
                      AND structural.text = ?
                      AND structural.embedding IS NULL
                      AND structural.embeddingFingerprint IS NULL
                      AND meeting.deletedAt IS NULL
                      AND \(currentStructuralTextSourceSQL)
                )
                """,
            arguments: [
                blob(from: vector),
                profile.fingerprint,
                candidate.id.uuidString,
                candidate.meetingID.rawValue.uuidString,
                correctionID.uuidString,
                candidate.transcriptRevision,
                candidate.text
            ])
    }

}

private enum SemanticEmbeddingSQL {
    static let requiresMaintenance = """
        SELECT EXISTS (
            SELECT 1
            FROM segment
            JOIN meeting ON meeting.id = segment.meetingID
            WHERE segment.deletedAt IS NULL
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.acceptedSegmentHasNoActiveTextCorrectionSQL)
              AND (
                  segment.embedding IS NULL
                  OR segment.embeddingFingerprint IS NOT ?
              )
            LIMIT 1
        )
        OR EXISTS (
            SELECT 1
            FROM segmentCorrectedText AS corrected
            JOIN segment ON segment.id = corrected.segmentID
            JOIN meeting ON meeting.id = corrected.meetingID
            JOIN transcriptCorrectionSearchState AS correctionState
              ON correctionState.meetingID = corrected.meetingID
            JOIN transcriptCorrection AS correction
              ON correction.id = corrected.correctionID
            WHERE segment.deletedAt IS NULL
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.currentCorrectedTextSourceSQL)
              AND (
                  corrected.embedding IS NULL
                  OR corrected.embeddingFingerprint IS NOT ?
              )
            LIMIT 1
        )
        OR EXISTS (
            SELECT 1
            FROM transcriptStructuralSearchRow AS structural
            JOIN meeting ON meeting.id = structural.meetingID
            JOIN transcriptCorrectionSearchState AS correctionState
              ON correctionState.meetingID = structural.meetingID
            JOIN transcriptCorrection AS correction
              ON correction.id = structural.correctionID
            WHERE meeting.deletedAt IS NULL
              AND \(MeetingStore.currentStructuralTextSourceSQL)
              AND (
                  structural.embedding IS NULL
                  OR structural.embeddingFingerprint IS NOT ?
              )
            LIMIT 1
        )
        """

    static let candidatesNeedingEmbeddings = """
        SELECT id, meetingID, transcriptRevision, text, source, correctionID
        FROM (
            SELECT segment.id AS id,
                   segment.meetingID AS meetingID,
                   meeting.transcriptRevision AS transcriptRevision,
                   segment.text AS text,
                   'accepted' AS source,
                   NULL AS correctionID,
                   segment.createdAt AS createdAt,
                   segment.rowid AS rowID
            FROM segment
            JOIN meeting ON meeting.id = segment.meetingID
                AND meeting.deletedAt IS NULL
            WHERE segment.embedding IS NULL
              AND segment.deletedAt IS NULL
              AND \(MeetingStore.acceptedSegmentHasNoActiveTextCorrectionSQL)
            UNION ALL
            SELECT segment.id AS id,
                   corrected.meetingID AS meetingID,
                   meeting.transcriptRevision AS transcriptRevision,
                   corrected.text AS text,
                   'corrected' AS source,
                   corrected.correctionID AS correctionID,
                   segment.createdAt AS createdAt,
                   segment.rowid AS rowID
            FROM segmentCorrectedText AS corrected
            JOIN segment ON segment.id = corrected.segmentID
            JOIN meeting ON meeting.id = corrected.meetingID
            JOIN transcriptCorrectionSearchState AS correctionState
              ON correctionState.meetingID = corrected.meetingID
            JOIN transcriptCorrection AS correction
              ON correction.id = corrected.correctionID
            WHERE corrected.embedding IS NULL
              AND segment.deletedAt IS NULL
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.currentCorrectedTextSourceSQL)
            UNION ALL
            SELECT structural.resultID AS id,
                   structural.meetingID AS meetingID,
                   meeting.transcriptRevision AS transcriptRevision,
                   structural.text AS text,
                   'structural' AS source,
                   structural.correctionID AS correctionID,
                   structural.updatedAt AS createdAt,
                   structural.rowid AS rowID
            FROM transcriptStructuralSearchRow AS structural
            JOIN meeting ON meeting.id = structural.meetingID
            JOIN transcriptCorrectionSearchState AS correctionState
              ON correctionState.meetingID = structural.meetingID
            JOIN transcriptCorrection AS correction
              ON correction.id = structural.correctionID
            WHERE structural.embedding IS NULL
              AND meeting.deletedAt IS NULL
              AND \(MeetingStore.currentStructuralTextSourceSQL)
        )
        ORDER BY createdAt, rowID, source
        LIMIT ?
        """
}
