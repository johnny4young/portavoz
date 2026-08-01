import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Local hybrid retrieval adapter owned by the Ask application workflow.
/// Exact FTS is always authoritative; semantic evidence is opportunistic and
/// reads only embeddings already published by the maintenance owner.
public struct LocalAskMeetingRetrieval: AskMeetingRetrieving {
    private let store: MeetingStore
    private let queryExpander: any AskQueryExpanding
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let semanticReadiness: ResolveSemanticCorpusReadiness

    public init(
        store: MeetingStore,
        queryExpander: any AskQueryExpanding = OnDeviceAskMeetingIntelligence(),
        runtime: any SemanticEmbeddingRuntimeClient,
        semanticReadiness: ResolveSemanticCorpusReadiness? = nil
    ) {
        self.store = store
        self.queryExpander = queryExpander
        self.runtime = runtime
        self.semanticReadiness = semanticReadiness
            ?? ResolveSemanticCorpusReadiness(
                store: store,
                runtime: runtime)
    }

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
        guard limit > 0 else { return [] }
        let hits = try await trace.measure(.lexicalQuery) { [store] in
            try await store.search(query, limit: limit)
        }
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
        let queries = await trace.measure(.expansion) {
            await queryExpander.expand(question)
        }
        let lexical = try await trace.measure(.lexicalQuery) {
            try await Self.retrieveLexical(
                queries: queries,
                store: store,
                limit: 12 * queries.count)
        }
        let readiness = try await trace.measure(.corpusReadiness) {
            try await semanticReadiness.current()
        }
        let semanticResult = try await semanticCandidates(
            queries: queries,
            readiness: readiness,
            trace: trace)
        let semantic = semanticResult.bestRank.sorted {
            $0.value < $1.value
        }.map(\.key)
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
        return await trace.measure(.citationFetch) {
            fused.compactMap { finalHitsByID[$0] }.map(Self.citation)
        }
    }

    private func semanticCandidates(
        queries: [String],
        readiness: SemanticCorpusReadiness,
        trace: AskPipelineTrace
    ) async throws -> SemanticCandidates {
        guard readiness.canSearchPublishedVectors else { return .empty }
        do {
            return try await runtime.withPreparedEmbedding(
                allowAssetDownload: false
            ) { [store, trace] embedder in
                let profile = await embedder.semanticEmbeddingProfile()
                let vectors = try await trace.measure(.queryEmbedding) {
                    try await embedder.vectors(for: queries)
                }
                return try await trace.measure(.semanticScan) {
                    try await Self.searchSemantic(
                        vectors: vectors,
                        profile: profile,
                        store: store)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .empty
        }
    }

    private static func searchSemantic(
        vectors: [[Float]],
        profile: SemanticEmbeddingProfile,
        store: MeetingStore
    ) async throws -> SemanticCandidates {
        var result = SemanticCandidates.empty
        for vector in vectors {
            for (rank, hit) in try await store.searchSemantic(
                vector,
                profile: profile,
                limit: 12
            ).enumerated()
            where result.bestRank[hit.segmentID].map({ rank < $0 }) ?? true {
                result.bestRank[hit.segmentID] = rank
                result.hitsByID[hit.segmentID] = hit
            }
        }
        return result
    }

    private static func citation(_ hit: SearchHit) -> AskCitation {
        AskCitation(
            segmentID: hit.segmentID,
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
            snippet: hit.snippet,
            timestamp: hit.startTime)
    }

    /// Lexical half of local RAG, public so the scale harness can measure the
    /// exact production candidate policy without loading embedding assets.
    public static func retrieveLexical(
        queries: [String],
        store: MeetingStore,
        limit: Int
    ) async throws -> [SearchHit] {
        guard limit > 0 else { return [] }
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
                limit: limit)
        }

        let perTermLimit = limit <= 48 ? max(64, limit * 4) : 256
        var hitsByID: [UUID: SearchHit] = [:]
        var scores: [UUID: Double] = [:]
        var bestRanks: [UUID: Int] = [:]
        for term in terms {
            for (rank, hit) in try await store.search(term, limit: perTermLimit).enumerated() {
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
        limit: Int
    ) async throws -> [SearchHit] {
        var hits: [SearchHit] = []
        var seen = Set<UUID>()
        for terms in queryTerms where !terms.isEmpty {
            let query = terms.joined(separator: " ")
            for hit in try await store.search(query, limit: min(12, limit), requireAll: false)
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
}

private struct SemanticCandidates: Sendable {
    var bestRank: [UUID: Int]
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
