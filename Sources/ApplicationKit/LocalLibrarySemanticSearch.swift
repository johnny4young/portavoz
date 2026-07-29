import Foundation
import PortavozCore
import StorageKit

/// Process-shared semantic fallback for instant Library search. Exact FTS
/// remains the first result lane; this actor only appends paraphrase and
/// cross-language matches after Apple's already-installed Latin embedding
/// model is ready. It never downloads an asset as a side effect of typing.
public actor LocalLibrarySemanticSearch {
    private let store: MeetingStore
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let corpusIndexer: IndexSemanticCorpus

    public init(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        telemetry: ResourceWorkloadTelemetry = .disabled
    ) {
        self.store = store
        self.runtime = runtime
        corpusIndexer = IndexSemanticCorpus(
            store: store,
            telemetry: telemetry)
    }

    public func search(
        _ query: String,
        limit: Int = 20
    ) async throws -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3, limit > 0,
            await runtime.hasAvailableAssets
        else { return [] }

        try Task.checkCancellation()
        return try await runtime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { [corpusIndexer, store] embedder in
            _ = try await corpusIndexer.nextBatch(
                using: embedder,
                limit: 512)
            try Task.checkCancellation()
            guard let vector = try await embedder.vectors(
                for: [query]
            ).first else { return [] }
            return try await store.searchSemantic(vector, limit: limit)
        }
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
