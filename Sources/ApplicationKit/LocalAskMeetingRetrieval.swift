import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Local hybrid retrieval adapter owned by the Ask application workflow:
/// index what's new, query both ways, then fuse by reciprocal rank.
public struct LocalAskMeetingRetrieval: AskMeetingRetrieving {
    private let store: MeetingStore
    private let queryExpander: any AskQueryExpanding

    public init(
        store: MeetingStore,
        queryExpander: any AskQueryExpanding = OnDeviceAskMeetingIntelligence()
    ) {
        self.store = store
        self.queryExpander = queryExpander
    }

    public func search(
        query: String,
        limit: Int
    ) async throws -> [AskSearchResult] {
        guard limit > 0 else { return [] }
        return try await store.search(query, limit: limit).map(Self.searchResult)
    }

    public func retrieve(
        question: String,
        limit: Int
    ) async throws -> [AskCitation] {
        // Index what's new, query lexically and semantically (multi-query,
        // cross-lingual when FM is around), then fuse by reciprocal rank.
        let embedder = try SentenceEmbedder()
        try await embedder.prepare()

        // Index anything new (idempotent, batched). Micro-segments carry no
        // retrievable meaning but drown real hits — empty marker excludes
        // them from semantic ranking for good.
        while true {
            let missing = try await store.segmentsNeedingEmbeddings(limit: 256)
            guard !missing.isEmpty else { break }
            let worthIndexing = missing.filter { $0.text.count >= 20 }
            let vectors = try await embedder.embed(worthIndexing.map(\.text))
            var update = Dictionary(uniqueKeysWithValues: zip(worthIndexing.map(\.id), vectors))
            for skipped in missing where skipped.text.count < 20 {
                update[skipped.id] = []
            }
            try await store.storeEmbeddings(update)
            if missing.count < 256 { break }
        }

        let queries = await queryExpander.expand(question)

        // Lexical: term-level top-k candidates over CONTENT words only.
        // Multi-term evidence climbs through reciprocal-rank fusion without
        // forcing FTS5 to score the entire broad OR union before LIMIT.
        let lexical = try await Self.retrieveLexical(
            queries: queries,
            store: store,
            limit: 12 * queries.count)

        // Semantic: best rank per segment across every query variant.
        let vectors = try await embedder.embed(queries)
        var bestRank: [UUID: Int] = [:]
        var hitsByID: [UUID: SearchHit] = [:]
        for vector in vectors {
            for (rank, hit) in try await store.searchSemantic(vector, limit: 12).enumerated()
            where bestRank[hit.segmentID].map({ rank < $0 }) ?? true {
                bestRank[hit.segmentID] = rank
                hitsByID[hit.segmentID] = hit
            }
        }
        let semantic = bestRank.sorted { $0.value < $1.value }.map(\.key)
        for hit in lexical where hitsByID[hit.segmentID] == nil {
            hitsByID[hit.segmentID] = hit
        }

        let fused = RAGFusion.fuse(
            lexical: lexical.map(\.segmentID),
            semantic: semantic,
            limit: limit)

        return fused.compactMap { hitsByID[$0] }.map { hit in
            AskCitation(
                segmentID: hit.segmentID,
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                timestamp: hit.startTime,
                text: hit.text)
        }
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
