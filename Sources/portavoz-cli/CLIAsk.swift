import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// `portavoz-cli ask "¿qué acordamos sobre el presupuesto?" [--db <path>]`
///
/// Local RAG (M8): embeds anything new, retrieves hybrid (FTS + cosine),
/// and answers on-device citing meeting + timestamp. Nothing leaves the
/// machine.
enum AskCommand {
    static func run(_ arguments: [String]) async {
        var positional: [String] = []
        var dbPath: String?
        var limit = 6

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--db":
                index += 1
                if index < arguments.count { dbPath = arguments[index] }
            case "--limit":
                index += 1
                if index < arguments.count { limit = Int(arguments[index]) ?? limit }
            default:
                positional.append(arguments[index])
            }
            index += 1
        }

        let question = positional.joined(separator: " ")
        guard !question.isEmpty else {
            print("Usage: portavoz-cli ask \"<pregunta>\" [--db <path>] [--limit n]")
            return
        }

        do {
            let store = try MeetingsCommand.openStore(dbPath: dbPath)
            let passages = try await AskPipeline.retrieve(
                question: question, store: store, limit: limit)
            guard !passages.isEmpty else {
                print("No encuentro nada relacionado en tus reuniones.")
                return
            }

            if #available(macOS 26.0, *),
                FoundationModelSummaryProvider.unavailabilityReason() == nil {
                let answer = try await RAGAnswerer().answer(question: question, passages: passages)
                print(answer)
            } else {
                print("(Apple Intelligence no disponible — esto es lo más relevante que encontré:)")
            }
            print("\nfuentes:")
            for (index, passage) in passages.enumerated() {
                print("  [\(index + 1)] \(passage.meetingTitle) · \(CLISupport.timestamp(passage.timestamp)) · \(passage.text.prefix(90))")
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}

/// Retrieval shared by `ask` and the MCP `ask` tool: index what's new,
/// query both ways, fuse by reciprocal rank.
enum AskPipeline {
    static func retrieve(
        question: String, store: MeetingStore, limit: Int = 6
    ) async throws -> [RAGPassage] {
        let embedder = try SentenceEmbedder()
        try await embedder.prepare()

        // Index anything new (idempotent, batched). Micro-segments carry
        // no retrievable meaning but, being same-language as the query,
        // they drown real hits — they get an empty marker instead of a
        // vector, which excludes them from semantic ranking for good.
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

        // Cross-lingual multi-query: the question plus FM paraphrases in
        // both library languages (falls back to the question alone).
        var queries = [question]
        if #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil {
            queries = await RAGAnswerer().expandQuery(question)
        }

        // Lexical: OR semantics over CONTENT words only — a question ANDed
        // token-by-token never matches, and OR over stopwords ("de",
        // "qué", "the") matches everything in that language.
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
            // FTS snippets carry [match] markers; the semantic copy (full
            // text) wins when both found it.
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
