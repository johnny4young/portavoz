import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

func semanticTestProfile(
    dimension: Int = 2,
    modelRevision: Int = 1,
    pipelineRevision: Int = 1,
    vectorSchemaVersion: Int = 1
) -> SemanticEmbeddingProfile {
    SemanticEmbeddingProfile(
        modelIdentifier: "portavoz.tests.semantic",
        modelRevision: modelRevision,
        vectorDimension: dimension,
        pipelineIdentifier: "deterministic-test-vectors",
        pipelineRevision: pipelineRevision,
        vectorSchemaVersion: vectorSchemaVersion)
}

extension SemanticTextEmbedding {
    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile {
        semanticTestProfile()
    }
}

extension SemanticEmbeddingRuntimeClient {
    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile? {
        semanticTestProfile()
    }
}

extension MeetingStore {
    func storeEmbeddings(
        _ embeddings: [UUID: [Float]],
        for candidates: [SemanticEmbeddingCandidate]
    ) async throws -> SemanticEmbeddingPublicationResult {
        let dimension = embeddings.values.first(where: { !$0.isEmpty })?.count ?? 2
        return try await storeEmbeddings(
            embeddings,
            for: candidates,
            profile: semanticTestProfile(dimension: dimension))
    }

    func searchSemantic(
        _ query: [Float],
        limit: Int = 8
    ) async throws -> [SearchHit] {
        try await searchSemantic(
            query,
            profile: semanticTestProfile(dimension: max(query.count, 2)),
            limit: limit)
    }
}
