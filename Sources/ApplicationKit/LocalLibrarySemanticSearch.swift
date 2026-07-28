import Foundation
import IntelligenceKit
import StorageKit

/// Process-shared semantic fallback for instant Library search. Exact FTS
/// remains the first result lane; this actor only appends paraphrase and
/// cross-language matches after Apple's already-installed Latin embedding
/// model is ready. It never downloads an asset as a side effect of typing.
public actor LocalLibrarySemanticSearch {
    private let store: MeetingStore
    private let embedder: SentenceEmbedder?

    public init(store: MeetingStore) {
        self.store = store
        embedder = try? SentenceEmbedder()
    }

    public func search(
        _ query: String,
        limit: Int = 20
    ) async throws -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3, limit > 0, let embedder,
            await embedder.hasAvailableAssets
        else { return [] }

        try Task.checkCancellation()
        try await embedder.prepare(allowAssetDownload: false)
        try await indexNextBatch(using: embedder)
        try Task.checkCancellation()
        guard let vector = try await embedder.embed([query]).first else { return [] }
        return try await store.searchSemantic(vector, limit: limit)
    }

    /// Indexing is deliberately bounded per query. A large library becomes
    /// semantic incrementally rather than monopolizing CPU while the user is
    /// trying to search; Ask's explicit deep-retrieval flow may still finish
    /// the complete index.
    private func indexNextBatch(using embedder: SentenceEmbedder) async throws {
        let missing = try await store.segmentsNeedingEmbeddings(limit: 512)
        guard !missing.isEmpty else { return }
        try Task.checkCancellation()
        let worthIndexing = missing.filter { $0.text.count >= 20 }
        let vectors = try await embedder.embed(worthIndexing.map(\.text))
        try Task.checkCancellation()
        var update = Dictionary(uniqueKeysWithValues: zip(worthIndexing.map(\.id), vectors))
        for skipped in missing where skipped.text.count < 20 {
            update[skipped.id] = []
        }
        try await store.storeEmbeddings(update)
    }
}

/// Library search protects precise text matches: semantic retrieval augments
/// them but never pushes an exact hit down the list.
public enum LibrarySearchFusion {
    public static func exactFirst<ID: Hashable>(
        lexical: [ID],
        semantic: [ID],
        limit: Int
    ) -> [ID] {
        guard limit > 0 else { return [] }
        var seen = Set<ID>()
        var result: [ID] = []
        result.reserveCapacity(min(limit, lexical.count + semantic.count))
        for id in lexical + semantic where seen.insert(id).inserted {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }
}
