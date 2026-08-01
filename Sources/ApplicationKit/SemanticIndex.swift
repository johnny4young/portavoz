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
}

/// Shipped exact semantic control: SQLite streams compatible vector BLOBs and
/// Accelerate scores cosine similarity while retaining only bounded top-k.
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
}
