import PortavozCore
import StorageKit

/// Read-only semantic query port used by product retrieval consumers.
///
/// Storage remains the citation authority: every adapter returns current
/// `SearchHit` projections with exact segment identity and transcript revision.
/// Candidate engines can therefore be evaluated behind this boundary without
/// changing Ask, Library, corpus maintenance, or authoritative meeting data.
public protocol SemanticIndexSearching: Sendable {
    func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit]

    /// Scores several variants of one question. Results correspond positionally
    /// to `queries`. An adapter that cannot fuse the work keeps the default,
    /// which is exactly the previous per-variant behavior.
    func search(
        _ queries: [[Float]],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [[SearchHit]]
}

public extension SemanticIndexSearching {
    func search(
        _ queries: [[Float]],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [[SearchHit]] {
        var results: [[SearchHit]] = []
        results.reserveCapacity(queries.count)
        for query in queries {
            results.append(
                try await search(query, profile: profile, limit: limit))
        }
        return results
    }
}

/// Shipped exact semantic control: SQLite streams compatible vector BLOBs and
/// Accelerate scores cosine similarity while retaining only bounded top-k.
///
/// The batch entry point scores every variant during one corpus traversal, so
/// bilingual expansion costs one scan instead of one per variant.
public struct AccelerateExactSemanticIndex: SemanticIndexSearching {
    private let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    public func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit] {
        try await store.searchSemantic(
            query,
            profile: profile,
            limit: limit)
    }

    public func search(
        _ queries: [[Float]],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [[SearchHit]] {
        try await store.searchSemantic(
            queries,
            profile: profile,
            limit: limit)
    }
}
