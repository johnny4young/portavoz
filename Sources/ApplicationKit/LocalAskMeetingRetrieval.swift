import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Local hybrid retrieval adapter owned by the Ask application workflow.
/// Exact FTS is always authoritative; semantic evidence is opportunistic and
/// reads only embeddings already published by the maintenance owner.
public struct LocalAskMeetingRetrieval: AskMeetingRetrieving {
    static let librarySemanticCandidateLimit = 12
    static let meetingSemanticCandidateLimit = 256

    private let store: MeetingStore
    private let lexicalExpander: BilingualSearchQueryExpander
    private let queryExpander: any AskQueryExpanding
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let semanticReadiness: ResolveSemanticCorpusReadiness
    private let semanticIndex: any SemanticIndexSearching

    public init(
        store: MeetingStore,
        lexicalExpander: BilingualSearchQueryExpander = .init(),
        queryExpander: any AskQueryExpanding = OnDeviceAskMeetingIntelligence(),
        runtime: any SemanticEmbeddingRuntimeClient,
        semanticReadiness: ResolveSemanticCorpusReadiness? = nil,
        semanticIndex: (any SemanticIndexSearching)? = nil
    ) {
        self.store = store
        self.lexicalExpander = lexicalExpander
        self.queryExpander = queryExpander
        self.runtime = runtime
        self.semanticReadiness = semanticReadiness
            ?? ResolveSemanticCorpusReadiness(
                store: store,
                runtime: runtime)
        self.semanticIndex = semanticIndex
            ?? AccelerateExactSemanticIndex(store: store)
    }
}

extension LocalAskMeetingRetrieval {
    public func search(
        query: String,
        limit: Int
    ) async throws -> [AskSearchResult] {
        try await search(
            query: query,
            limit: limit,
            trace: AskPipelineTelemetry.disabledTrace(for: .search))
    }

    public func search(
        query: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        try await search(
            query: query,
            source: .library,
            limit: limit,
            trace: trace)
    }

    public func search(
        query: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        guard limit > 0 else { return [] }
        let meetingID = try Self.meetingID(for: source)
        try Task.checkCancellation()
        let hits = try await trace.measure(.lexicalQuery) { [store] in
            try await store.search(
                query,
                meetingID: meetingID,
                limit: limit)
        }
        try Task.checkCancellation()
        return await trace.measure(.citationFetch) {
            hits.map(Self.searchResult)
        }
    }

    public func retrieve(
        question: String,
        limit: Int
    ) async throws -> [AskCitation] {
        try await retrieve(
            question: question,
            limit: limit,
            trace: AskPipelineTelemetry.disabledTrace(for: .evidence))
    }

    public func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskCitation] {
        try await retrieve(
            question: question,
            limit: limit,
            trace: trace,
            onEvidence: { _ in })
    }

    public func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        try await retrieve(
            question: question,
            source: .library,
            limit: limit,
            trace: trace,
            onEvidence: onEvidence)
    }

    public func retrieve(
        question: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        guard limit > 0 else {
            await onEvidence(AskEvidenceUpdate(phase: .fused, citations: []))
            return []
        }
        _ = try Self.meetingID(for: source)
        try Task.checkCancellation()
        let queries = await trace.measure(.expansion) { [lexicalExpander] in
            lexicalExpander.expand(question)
        }
        try Task.checkCancellation()
        async let semanticResult = semanticCandidates(
            queries: queries,
            source: source,
            trace: trace)
        let lexical = try await trace.measure(.lexicalQuery) { [store] in
            try await Self.retrieveLexical(
                queries: queries,
                store: store,
                source: source,
                limit: Self.candidateLimit(for: queries))
        }
        try Task.checkCancellation()
        await onEvidence(AskEvidenceUpdate(
            phase: .lexical,
            citations: lexical.prefix(limit).map(Self.citation)))
        try Task.checkCancellation()
        let semantic = try await semanticResult
        try Task.checkCancellation()
        var citations = try await fusedCitations(
            lexical: lexical,
            semanticResult: semantic,
            limit: limit,
            trace: trace)

        if citations.isEmpty {
            citations = try await lateFallback(
                question: question,
                excluding: queries,
                source: source,
                limit: limit,
                onEvidence: onEvidence)
        }
        try Task.checkCancellation()
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: citations))
        try Task.checkCancellation()
        return citations
    }

    private func fusedCitations(
        lexical: [SearchHit],
        semanticResult: SemanticCandidates,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskCitation] {
        try Task.checkCancellation()
        let semantic = Self.orderedSemanticCandidateIDs(
            semanticResult.bestRank)
        var hitsByID = semanticResult.hitsByID
        for hit in lexical where hitsByID[hit.segmentID] == nil {
            hitsByID[hit.segmentID] = hit
        }
        let finalHitsByID = hitsByID
        let fused = await trace.measure(.fusion) {
            RAGFusion.fuse(
                lexical: lexical.map(\.segmentID),
                semantic: semantic,
                limit: limit)
        }
        try Task.checkCancellation()
        return await trace.measure(.citationFetch) {
            fused.compactMap { finalHitsByID[$0] }.map(Self.citation)
        }
    }

    /// Foundation Models expansion is deliberately outside the first-evidence
    /// path. It runs only when deterministic bilingual lexical plus available
    /// semantic retrieval found nothing.
    private func lateFallback(
        question: String,
        excluding initialQueries: [String],
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        try Task.checkCancellation()
        let expanded = try await queryExpander.expand(question)
        try Task.checkCancellation()
        let queries = Self.uniqueQueries(expanded, excluding: initialQueries)
        guard !queries.isEmpty else { return [] }
        let trace = AskPipelineTelemetry.disabledTrace(for: .evidence)
        try Task.checkCancellation()
        async let semanticResult = semanticCandidates(
            queries: queries,
            source: source,
            trace: trace)
        let lexical = try await Self.retrieveLexical(
            queries: queries,
            store: store,
            source: source,
            limit: Self.candidateLimit(for: queries))
        try Task.checkCancellation()
        if !lexical.isEmpty {
            await onEvidence(AskEvidenceUpdate(
                phase: .lexical,
                citations: lexical.prefix(limit).map(Self.citation)))
            try Task.checkCancellation()
        }
        return try await fusedCitations(
            lexical: lexical,
            semanticResult: try await semanticResult,
            limit: limit,
            trace: trace)
    }

    private func semanticCandidates(
        queries: [String],
        source: AskSourceScope,
        trace: AskPipelineTrace
    ) async throws -> SemanticCandidates {
        do {
            let readiness = try await trace.measure(.corpusReadiness) {
                try await semanticReadiness.current()
            }
            guard readiness.canSearchPublishedVectors else { return .empty }
            return try await runtime.withPreparedEmbedding(
                allowAssetDownload: false
            ) { [semanticIndex, trace] embedder in
                let profile = await embedder.semanticEmbeddingProfile()
                let vectors = try await trace.measure(.queryEmbedding) {
                    try await embedder.vectors(for: queries)
                }
                return try await trace.measure(.semanticScan) {
                    try await Self.searchSemantic(
                        vectors: vectors,
                        profile: profile,
                        source: source,
                        semanticIndex: semanticIndex)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .empty
        }
    }

    private static func candidateLimit(for queries: [String]) -> Int {
        max(12, 12 * min(12, queries.count))
    }

    private static func uniqueQueries(
        _ candidates: [String],
        excluding excluded: [String]
    ) -> [String] {
        var seen = Set(excluded.map(queryKey))
        return Array(candidates.compactMap { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(queryKey(value)).inserted else {
                return nil
            }
            return value
        }.prefix(3))
    }

    private static func queryKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func searchSemantic(
        vectors: [[Float]],
        profile: SemanticEmbeddingProfile,
        source: AskSourceScope,
        semanticIndex: any SemanticIndexSearching
    ) async throws -> SemanticCandidates {
        var result = SemanticCandidates.empty
        let meetingID = try Self.meetingID(for: source)
        let candidateLimit = meetingID == nil
            ? librarySemanticCandidateLimit
            : meetingSemanticCandidateLimit
        // One traversal scores every variant; the fold keeps each segment's
        // best rank across variants, earliest variant winning a tie.
        try Task.checkCancellation()
        for (variant, variantHits) in try await semanticIndex.search(
            vectors,
            profile: profile,
            limit: candidateLimit
        ).enumerated() {
            try Task.checkCancellation()
            for (rank, hit) in variantHits.enumerated()
            where (meetingID.map { hit.meetingID == $0 } ?? true)
                && (result.bestRank[hit.segmentID].map({
                    SemanticCandidateRank(rank: rank, variant: variant) < $0
                }) ?? true) {
                result.bestRank[hit.segmentID] = SemanticCandidateRank(
                    rank: rank,
                    variant: variant)
                result.hitsByID[hit.segmentID] = hit
            }
        }
        return result
    }

    struct SemanticCandidateRank: Comparable, Sendable {
        let rank: Int
        let variant: Int

        static let worst = Self(rank: .max, variant: .max)

        static func < (left: Self, right: Self) -> Bool {
            if left.rank != right.rank { return left.rank < right.rank }
            return left.variant < right.variant
        }
    }

    /// A segment's best rank across variants is its semantic authority. The
    /// earlier deterministic variant wins equal ranks; stable UUID identity
    /// makes the remaining total-order tie independent of dictionary hashing.
    static func orderedSemanticCandidateIDs(
        _ bestRank: [UUID: SemanticCandidateRank]
    ) -> [UUID] {
        bestRank.keys.sorted { left, right in
            let leftRank = bestRank[left, default: .worst]
            let rightRank = bestRank[right, default: .worst]
            if leftRank != rightRank { return leftRank < rightRank }
            return left.uuidString < right.uuidString
        }
    }

    private static func citation(_ hit: SearchHit) -> AskCitation {
        AskCitation(
            segmentID: hit.segmentID,
            sourceSegmentIDs: hit.sourceSegmentIDs,
            meetingID: hit.meetingID,
            meetingTitle: hit.meetingTitle,
            timestamp: hit.startTime,
            transcriptRevision: hit.transcriptRevision,
            text: hit.text)
    }

    private static func searchResult(_ hit: SearchHit) -> AskSearchResult {
        AskSearchResult(
            meetingID: hit.meetingID,
            meetingTitle: hit.meetingTitle,
            segmentID: hit.segmentID,
            sourceSegmentIDs: hit.sourceSegmentIDs,
            snippet: hit.snippet,
            timestamp: hit.startTime)
    }

    /// Lexical half of local RAG, public so the scale harness can measure the
    /// exact production candidate policy without loading embedding assets.
    public static func retrieveLexical(
        queries: [String],
        store: MeetingStore,
        source: AskSourceScope = .library,
        limit: Int
    ) async throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let meetingID = try meetingID(for: source)
        try Task.checkCancellation()
        let queryTerms = queries.map(Self.contentTerms)
        let terms = Self.uniqueTerms(queryTerms.flatMap { $0 })
        guard !terms.isEmpty else { return [] }

        // Query expansion is intentionally terse (at most three variants).
        // A user can still paste a paragraph; keep that unusual shape on the
        // released broad-OR path instead of multiplying many FTS scans.
        guard terms.count <= 8 else {
            return try await retrieveBroadFallback(
                queryTerms: queryTerms,
                store: store,
                meetingID: meetingID,
                limit: limit)
        }

        let perTermLimit = limit <= 48 ? max(64, limit * 4) : 256
        var hitsByID: [UUID: SearchHit] = [:]
        var scores: [UUID: Double] = [:]
        var bestRanks: [UUID: Int] = [:]
        for term in terms {
            try Task.checkCancellation()
            let termHits = try await store.search(
                term,
                meetingID: meetingID,
                limit: perTermLimit)
            try Task.checkCancellation()
            for (rank, hit) in termHits.enumerated() {
                scores[hit.segmentID, default: 0] += 1.0 / Double(60 + rank)
                if rank < (bestRanks[hit.segmentID] ?? .max) {
                    hitsByID[hit.segmentID] = hit
                    bestRanks[hit.segmentID] = rank
                }
            }
        }

        return scores.keys.sorted { left, right in
            if scores[left] != scores[right] {
                return scores[left, default: 0] > scores[right, default: 0]
            }
            if bestRanks[left] != bestRanks[right] {
                return bestRanks[left, default: .max] < bestRanks[right, default: .max]
            }
            return left.uuidString < right.uuidString
        }.prefix(limit).compactMap { hitsByID[$0] }
    }

    private static func retrieveBroadFallback(
        queryTerms: [[String]],
        store: MeetingStore,
        meetingID: MeetingID?,
        limit: Int
    ) async throws -> [SearchHit] {
        var hits: [SearchHit] = []
        var seen = Set<UUID>()
        for terms in queryTerms where !terms.isEmpty {
            try Task.checkCancellation()
            let query = terms.joined(separator: " ")
            let queryHits = try await store.search(
                query,
                meetingID: meetingID,
                limit: min(12, limit),
                requireAll: false)
            try Task.checkCancellation()
            for hit in queryHits
            where seen.insert(hit.segmentID).inserted {
                hits.append(hit)
            }
        }
        return Array(hits.prefix(limit))
    }

    private static func contentTerms(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 }
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { term in
            let key = term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            return seen.insert(key).inserted
        }
    }

    private static func meetingID(
        for source: AskSourceScope
    ) throws -> MeetingID? {
        switch source {
        case .library:
            nil
        case .meeting(let meetingID):
            meetingID
        case .notes:
            throw AskSourcePolicyError.notesRequireTypedAdapter
        case .web:
            throw AskSourcePolicyError.webUnavailable
        }
    }
}

private struct SemanticCandidates: Sendable {
    var bestRank: [UUID: LocalAskMeetingRetrieval.SemanticCandidateRank]
    var hitsByID: [UUID: SearchHit]

    static let empty = Self(bestRank: [:], hitsByID: [:])
}

private extension AskPipelineTelemetry {
    static func disabledTrace(
        for operation: AskPipelineOperation
    ) -> AskPipelineTrace {
        AskPipelineTrace(
            identity: AskPipelineTraceIdentity(operation: operation),
            receiver: { _ in })
    }
}
