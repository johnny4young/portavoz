import PortavozCore
import StorageKit

/// Research-engine boundary. Implementations return only ordered source
/// identity; they cannot construct or become the authority for citation text.
public protocol SemanticIndexShadowRanking: Sendable {
    var adapter: SemanticIndexShadowAdapter { get }

    func rankedCandidates(
        for query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SemanticSearchCandidateIdentity]
}

/// Candidate adapter that revision-fences derived ranks through MeetingStore.
/// No candidate-provided content crosses the semantic query port.
public struct ProjectedSemanticIndexShadowCandidate: SemanticIndexShadowCandidateSearching {
    private let ranker: any SemanticIndexShadowRanking
    private let store: MeetingStore

    public var adapter: SemanticIndexShadowAdapter { ranker.adapter }

    public init(
        ranker: any SemanticIndexShadowRanking,
        store: MeetingStore
    ) {
        self.ranker = ranker
        self.store = store
    }

    public func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let candidates = try await ranker.rankedCandidates(
            for: query,
            profile: profile,
            limit: limit)
        return try await store.projectSemanticSearchCandidates(
            candidates,
            limit: limit)
    }
}
