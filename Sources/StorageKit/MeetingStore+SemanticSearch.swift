import Accelerate
import Foundation
import GRDB
import PortavozCore

// Exact local semantic retrieval and authoritative result projection.
extension MeetingStore {
    private static let acceptedSemanticScanSQL = """
        SELECT segment.embedding AS embedding,
               segment.rowid AS rowID,
               0 AS isCorrected,
               NULL AS correctionID
        FROM segment
        WHERE segment.embedding IS NOT NULL
          AND segment.embeddingFingerprint = ?
          AND segment.deletedAt IS NULL
          AND segment.meetingID NOT IN (
              SELECT meeting.id FROM meeting WHERE meeting.deletedAt IS NOT NULL
          )
          AND \(acceptedSegmentHasNoActiveTextCorrectionSQL)
        ORDER BY segment.rowid ASC
        """

    private static let correctedSemanticScanSQL = """
        SELECT segment.embedding AS embedding,
               segment.rowid AS rowID,
               0 AS isCorrected,
               NULL AS correctionID
        FROM segment
        WHERE segment.embedding IS NOT NULL
          AND segment.embeddingFingerprint = ?
          AND segment.deletedAt IS NULL
          AND segment.meetingID NOT IN (
              SELECT meeting.id FROM meeting WHERE meeting.deletedAt IS NOT NULL
          )
          AND \(acceptedSegmentHasNoActiveTextCorrectionSQL)
        UNION ALL
        SELECT corrected.embedding AS embedding,
               segment.rowid AS rowID,
               1 AS isCorrected,
               corrected.correctionID AS correctionID
        FROM segmentCorrectedText AS corrected
        JOIN segment ON segment.id = corrected.segmentID
        JOIN meeting ON meeting.id = corrected.meetingID
        JOIN transcriptCorrectionSearchState AS correctionState
          ON correctionState.meetingID = corrected.meetingID
        JOIN transcriptCorrection AS correction
          ON correction.id = corrected.correctionID
        WHERE corrected.embedding IS NOT NULL
          AND corrected.embeddingFingerprint = ?
          AND segment.deletedAt IS NULL
          AND meeting.deletedAt IS NULL
          AND \(currentCorrectedTextSourceSQL)
        ORDER BY rowID ASC, isCorrected ASC
        """

    /// Exact cosine top-k over every embedded segment. Embeddings are
    /// normalized at write time, so cosine is a dot product. Rows stream from
    /// SQLite, BLOB bytes are scored without a Float-array copy, and only the
    /// bounded best candidates survive (D83).
    public func searchSemantic(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int = 8
    ) async throws -> [SearchHit] {
        try await searchSemantic([query], profile: profile, limit: limit)
            .first ?? []
    }

    /// The same exact top-k, scoring every query variant during **one** corpus
    /// traversal. Bilingual expansion asks several variants of one question, so
    /// scanning per variant multiplied the streamed BLOB volume by the variant
    /// count for no additional evidence.
    ///
    /// Results correspond positionally to `queries`; a query that does not
    /// match the profile contributes an empty result instead of dropping the
    /// alignment its caller ranks by.
    public func searchSemantic(
        _ queries: [[Float]],
        profile: SemanticEmbeddingProfile,
        limit: Int = 8
    ) async throws -> [[SearchHit]] {
        guard let batch = SemanticQueryBatch(
            queries: queries,
            profile: profile,
            limit: limit)
        else { return [[SearchHit]](repeating: [], count: queries.count) }
        return try await database.read { db in
            try Self.searchSemantic(batch, in: db)
        }
    }

    private static func searchSemantic(
        _ batch: SemanticQueryBatch,
        in database: Database
    ) throws -> [[SearchHit]] {
        let candidates = try semanticCandidates(for: batch, in: database)
        var results = [[SearchHit]](
            repeating: [],
            count: batch.resultCount)
        for (slot, resultIndex) in batch.scoredIndices.enumerated() {
            results[resultIndex] = try Self.semanticHits(
                in: database,
                candidates: candidates[slot])
        }
        return results
    }

    private static func semanticCandidates(
        for batch: SemanticQueryBatch,
        in database: Database
    ) throws -> [[SemanticCandidate]] {
        let scan = try semanticScan(
            profileFingerprint: batch.profileFingerprint,
            in: database)
        let rows = try Row.fetchCursor(
            database,
            sql: scan.sql,
            arguments: scan.arguments)
        var candidates = [[SemanticCandidate]](
            repeating: [],
            count: batch.scoredIndices.count)
        for slot in candidates.indices {
            candidates[slot].reserveCapacity(min(batch.limit, 64))
        }
        var traversalOrder = 0

        try batch.flattenedQueries.withUnsafeBufferPointer { queryBuffer in
            // Slice each variant once and mutate candidate slots through one
            // buffer; rebasing or inout subscripting per row multiplies work.
            let variants = (0..<batch.scoredIndices.count).map { slot in
                UnsafeBufferPointer(
                    rebasing: queryBuffer[
                        (slot * batch.dimension)..<((slot + 1) * batch.dimension)])
            }
            try candidates.withUnsafeMutableBufferPointer { admitted in
                while let row = try rows.next() {
                    let order = traversalOrder
                    traversalOrder += 1
                    try row.withUnsafeData(atIndex: 0) { blob in
                        guard let blob else { return }
                        let rowID: Int64 = row["rowID"]
                        let source = try semanticCandidateSource(from: row)
                        for slot in variants.indices {
                            guard let score = semanticDotProduct(
                                blob,
                                query: variants[slot],
                                expectedBytes: batch.expectedBytes)
                            else { continue }
                            admit(
                                score: score,
                                order: order,
                                rowID: rowID,
                                source: source,
                                into: &admitted[slot],
                                limit: batch.limit)
                        }
                    }
                }
            }
        }
        return candidates
    }

    private static func semanticScan(
        profileFingerprint: String,
        in database: Database
    ) throws -> (sql: String, arguments: StatementArguments) {
        let hasCorrectedVectors = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM segmentCorrectedText AS corrected
                    JOIN segment ON segment.id = corrected.segmentID
                    JOIN meeting ON meeting.id = corrected.meetingID
                    JOIN transcriptCorrectionSearchState AS correctionState
                      ON correctionState.meetingID = corrected.meetingID
                    JOIN transcriptCorrection AS correction
                      ON correction.id = corrected.correctionID
                    WHERE corrected.embedding IS NOT NULL
                      AND corrected.embeddingFingerprint = ?
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                      AND \(currentCorrectedTextSourceSQL)
                    LIMIT 1
                )
                """,
            arguments: [profileFingerprint]) ?? false
        if hasCorrectedVectors {
            return (
                correctedSemanticScanSQL,
                [profileFingerprint, profileFingerprint])
        }
        return (acceptedSemanticScanSQL, [profileFingerprint])
    }

    private static func semanticCandidateSource(
        from row: Row
    ) throws -> SemanticEmbeddingCandidate.Source {
        let isCorrected: Bool = row["isCorrected"]
        guard isCorrected else { return .accepted }
        return .corrected(correctionID: try PersistedIdentity.required(
            row["correctionID"],
            table: "segmentCorrectedText",
            column: "correctionID"))
    }

    /// Bounded insertion into one variant's top-k, preserving the exact
    /// score-then-traversal-order tie-break of the single-query scan.
    private static func admit(
        score: Float,
        order: Int,
        rowID: Int64,
        source: SemanticEmbeddingCandidate.Source,
        into candidates: inout [SemanticCandidate],
        limit: Int
    ) {
        if candidates.count == limit,
           let worst = candidates.last,
           !SemanticCandidate.isBetter(score: score, order: order, than: worst) {
            return
        }
        let candidate = SemanticCandidate(
            score: score,
            order: order,
            rowID: rowID,
            source: source)
        let insertionIndex = candidates.firstIndex {
            candidate.isBetter(than: $0)
        } ?? candidates.endIndex
        candidates.insert(candidate, at: insertionIndex)
        if candidates.count > limit { candidates.removeLast() }
    }

    /// Resolves ordered derived-index identities through current authoritative
    /// transcript rows. Missing, deleted, duplicate, invalid-revision, or stale
    /// candidates are omitted without allowing later ranks to exceed `limit`.
    /// This research identity carries no correction UUID/revision, so an active
    /// text correction is deliberately omitted instead of rehydrating a stale
    /// rank against different corrected material.
    public func projectSemanticSearchCandidates(
        _ candidates: [SemanticSearchCandidateIdentity],
        limit: Int
    ) async throws -> [SearchHit] {
        let ordered = Self.semanticProjectionCandidates(candidates, limit: limit)
        guard !ordered.isEmpty else { return [] }
        return try await database.read { database in
            try Self.projectSemanticSearchCandidates(ordered, in: database)
        }
    }

    private static func semanticProjectionCandidates(
        _ candidates: [SemanticSearchCandidateIdentity],
        limit: Int
    ) -> [SemanticSearchCandidateIdentity] {
        guard limit > 0 else { return [] }
        var seen: Set<UUID> = []
        var ordered: [SemanticSearchCandidateIdentity] = []
        ordered.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates.prefix(limit) where candidate.transcriptRevision >= 0 {
            guard seen.insert(candidate.segmentID).inserted else { continue }
            ordered.append(candidate)
        }
        return ordered
    }

    private static func projectSemanticSearchCandidates(
        _ ordered: [SemanticSearchCandidateIdentity],
        in database: Database
    ) throws -> [SearchHit] {
        let current = try acceptedSemanticProjectionHits(
            segmentIDs: ordered.map(\.segmentID),
            in: database)
        return ordered.compactMap { candidate in
            guard let hit = current[candidate.segmentID],
                  hit.transcriptRevision == candidate.transcriptRevision
            else { return nil }
            return hit
        }
    }

    private static func acceptedSemanticProjectionHits(
        segmentIDs: [UUID],
        in database: Database
    ) throws -> [UUID: SearchHit] {
        let segmentKeys = segmentIDs.map(\.uuidString)
        let rows = try Row.fetchAll(
            database,
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
                  AND \(Self.acceptedSegmentHasNoActiveTextCorrectionSQL)
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
        return current
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
        let acceptedRowIDs = candidates.compactMap { candidate in
            candidate.source == .accepted ? candidate.rowID : nil
        }
        let correctedRowIDs = candidates.compactMap { candidate in
            if case .corrected = candidate.source { return candidate.rowID }
            return nil
        }
        var hits = try semanticAcceptedHits(
            in: database,
            rowIDs: acceptedRowIDs)
        hits.merge(
            try semanticCorrectedHits(in: database, rowIDs: correctedRowIDs),
            uniquingKeysWith: { current, _ in current })
        return try candidates.map { candidate in
            let key = SemanticCandidateKey(
                rowID: candidate.rowID,
                source: candidate.source)
            guard let hit = hits[key] else {
                throw StorageError.invalidPersistedValue(
                    table: "segment", column: "rowid", value: String(candidate.rowID))
            }
            return SearchHit(
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                segmentID: hit.segmentID,
                text: hit.text,
                snippet: hit.snippet,
                startTime: hit.startTime,
                transcriptRevision: hit.transcriptRevision,
                semanticSimilarity: candidate.score)
        }
    }

    private static func semanticAcceptedHits(
        in database: Database,
        rowIDs: [Int64]
    ) throws -> [SemanticCandidateKey: SearchHit] {
        var hits: [SemanticCandidateKey: SearchHit] = [:]
        hits.reserveCapacity(rowIDs.count)
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
                      AND \(Self.acceptedSegmentHasNoActiveTextCorrectionSQL)
                    """,
                arguments: StatementArguments(chunk))
            for row in rows {
                let rowID: Int64 = row["rowID"]
                hits[SemanticCandidateKey(rowID: rowID, source: .accepted)] = SearchHit(
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
        return hits
    }

    private static func semanticCorrectedHits(
        in database: Database,
        rowIDs: [Int64]
    ) throws -> [SemanticCandidateKey: SearchHit] {
        var hits: [SemanticCandidateKey: SearchHit] = [:]
        hits.reserveCapacity(rowIDs.count)
        for lowerBound in stride(from: 0, to: rowIDs.count, by: 500) {
            let upperBound = min(lowerBound + 500, rowIDs.count)
            let chunk = Array(rowIDs[lowerBound..<upperBound])
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT segment.rowid AS rowID,
                           segment.id AS segmentID,
                           corrected.meetingID AS meetingID,
                           segment.startTime AS startTime,
                           corrected.text AS text,
                           corrected.correctionID AS correctionID,
                           meeting.title AS title,
                           meeting.transcriptRevision AS transcriptRevision
                    FROM segmentCorrectedText AS corrected
                    JOIN segment ON segment.id = corrected.segmentID
                    JOIN meeting ON meeting.id = corrected.meetingID
                    JOIN transcriptCorrectionSearchState AS correctionState
                      ON correctionState.meetingID = corrected.meetingID
                    JOIN transcriptCorrection AS correction
                      ON correction.id = corrected.correctionID
                    WHERE segment.rowid IN (\(databaseQuestionMarks(count: chunk.count)))
                      AND segment.deletedAt IS NULL
                      AND meeting.deletedAt IS NULL
                      AND \(currentCorrectedTextSourceSQL)
                    """,
                arguments: StatementArguments(chunk))
            for row in rows {
                let rowID: Int64 = row["rowID"]
                let correctionID = try PersistedIdentity.required(
                    row["correctionID"],
                    table: "segmentCorrectedText",
                    column: "correctionID")
                let source = SemanticEmbeddingCandidate.Source.corrected(
                    correctionID: correctionID)
                hits[SemanticCandidateKey(rowID: rowID, source: source)] = SearchHit(
                    meetingID: MeetingID(rawValue: try PersistedIdentity.required(
                        row["meetingID"],
                        table: "segmentCorrectedText",
                        column: "meetingID")),
                    meetingTitle: row["title"],
                    segmentID: try PersistedIdentity.required(
                        row["segmentID"], table: "segment", column: "id"),
                    text: row["text"],
                    snippet: row["text"],
                    startTime: row["startTime"],
                    transcriptRevision: row["transcriptRevision"])
            }
        }
        return hits
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

private struct SemanticQueryBatch: Sendable {
    let resultCount: Int
    let scoredIndices: [Int]
    let flattenedQueries: [Float]
    let dimension: Int
    let expectedBytes: Int
    let profileFingerprint: String
    let limit: Int

    init?(
        queries: [[Float]],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) {
        guard profile.isValid, limit > 0, !queries.isEmpty else { return nil }
        let (expectedBytes, overflow) = profile.vectorDimension
            .multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !overflow else { return nil }

        // Preserve positions so one unusable variant contributes an empty slot
        // instead of shifting the caller's cross-variant ranking inputs.
        let scoredIndices = queries.indices.filter { index in
            queries[index].count == profile.vectorDimension
                && queries[index].allSatisfy(\.isFinite)
        }
        guard !scoredIndices.isEmpty else { return nil }

        resultCount = queries.count
        self.scoredIndices = scoredIndices
        flattenedQueries = scoredIndices.flatMap { queries[$0] }
        dimension = profile.vectorDimension
        self.expectedBytes = expectedBytes
        profileFingerprint = profile.fingerprint
        self.limit = limit
    }
}

private struct SemanticCandidate {
    let score: Float
    let order: Int
    let rowID: Int64
    let source: SemanticEmbeddingCandidate.Source

    func isBetter(than other: SemanticCandidate) -> Bool {
        Self.isBetter(score: score, order: order, than: other)
    }

    static func isBetter(score: Float, order: Int, than other: SemanticCandidate) -> Bool {
        score > other.score || (score == other.score && order < other.order)
    }
}

private struct SemanticCandidateKey: Hashable {
    let rowID: Int64
    let source: SemanticEmbeddingCandidate.Source
}
