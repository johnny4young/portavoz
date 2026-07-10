import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// Retrieval shared by the app's Ask view, the CLI `ask` command and the
/// MCP `ask` tool (M8): index what's new, query both ways, fuse by
/// reciprocal rank. Lives here because IntegrationsKit is the one Kit
/// allowed to see both StorageKit and IntelligenceKit (D31).
public enum AskPipeline {
    /// Index what's new, query lexically and semantically (multi-query,
    /// cross-lingual when FM is around), fuse by reciprocal rank.
    public static func retrieve(
        question: String, store: MeetingStore, limit: Int = 6
    ) async throws -> [RAGPassage] {
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

        var queries = [question]
        if #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            queries = await RAGAnswerer().expandQuery(question)
        }

        // Lexical: OR semantics over CONTENT words only.
        var lexical: [SearchHit] = []
        var seenLexical = Set<UUID>()
        for query in queries {
            let keywords = query.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count >= 4 }
                .joined(separator: " ")
            guard !keywords.isEmpty else { continue }
            for hit in try await store.search(keywords, limit: 12, requireAll: false)
            where seenLexical.insert(hit.segmentID).inserted {
                lexical.append(hit)
            }
        }

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
            RAGPassage(
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                timestamp: hit.startTime,
                text: hit.snippet
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: ""))
        }
    }
}
