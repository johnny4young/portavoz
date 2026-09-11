import ApplicationKit
import PortavozCore
import StorageKit

/// Only one sequential benchmark query owns this recorder. The real retrieval
/// joins its semantic child and awaits evidence delivery before finish.
actor AskQualityStageRecorder {
    private let mapping: AskQualityCorpusMapping
    private var lexical: [AskQualityHitObservation]?
    private var fused: [AskQualityHitObservation]?
    private var requests: [AskQualitySemanticRequest] = []
    private var error: AskQualityAttributionError?

    init(mapping: AskQualityCorpusMapping) { self.mapping = mapping }

    func begin() {
        lexical = nil
        fused = nil
        requests.removeAll(keepingCapacity: true)
        error = nil
    }

    func record(_ update: AskEvidenceUpdate) {
        do {
            let hits = try update.citations.map { try mapping.observation(for: $0) }
            switch update.phase {
            case .lexical:
                if lexical != nil { error = .incompleteStages }
                lexical = hits
            case .fused:
                if fused != nil { error = .incompleteStages }
                fused = hits
            }
        } catch {
            self.error = .incompleteStages
        }
    }

    func rejectProfile() { error = .profileChanged }

    func recordSemantic(
        outcome: AskQualitySemanticRequest.Outcome,
        profile: SemanticEmbeddingProfile,
        limit: Int,
        vectors: [[Float]],
        hits: [[SearchHit]]
    ) {
        guard requests.isEmpty, !vectors.isEmpty, vectors.count <= 12,
              limit > 0, limit <= 256,
              outcome == .succeeded ? hits.count == vectors.count : hits.isEmpty,
              hits.allSatisfy({ $0.count <= limit })
        else {
            error = .incompleteStages
            return
        }
        do {
            requests.append(AskQualitySemanticRequest(
                outcome: outcome, profileFingerprint: profile.fingerprint,
                candidateLimit: limit,
                queryVectors: .measure(
                    vectors, requested: vectors.count, dimension: profile.vectorDimension),
                variants: try hits.map { variant in
                    try variant.map { try mapping.observation(for: $0) }
                }))
        } catch {
            self.error = .incompleteStages
        }
    }

    func finish(
        queryID: String, finalHits: [AskQualityHitObservation]
    ) throws -> AskQualityStageEvidence {
        if let error { throw error }
        guard let lexical, fused == finalHits else {
            throw AskQualityAttributionError.incompleteStages
        }
        return AskQualityStageEvidence(
            queryID: queryID, lexical: lexical, semanticRequests: requests)
    }
}

struct AskQualityMeasuredIndex: SemanticIndexSearching {
    let underlying: any SemanticIndexSearching
    let recorder: AskQualityStageRecorder
    let profile: SemanticEmbeddingProfile

    func search(
        _ query: [Float], profile: SemanticEmbeddingProfile, limit: Int
    ) async throws -> [SearchHit] {
        try await search([query], profile: profile, limit: limit).first ?? []
    }

    func search(
        _ queries: [[Float]], profile: SemanticEmbeddingProfile, limit: Int
    ) async throws -> [[SearchHit]] {
        guard profile == self.profile else {
            await recorder.rejectProfile()
            throw AskQualityAttributionError.profileChanged
        }
        do {
            let hits = try await underlying.search(queries, profile: profile, limit: limit)
            await recorder.recordSemantic(
                outcome: .succeeded, profile: profile, limit: limit,
                vectors: queries, hits: hits)
            return hits
        } catch {
            // Preserve the product's cancellation/fallback behavior. Never
            // encode the underlying error or turn a failed scan into success.
            await recorder.recordSemantic(
                outcome: .failed, profile: profile, limit: limit,
                vectors: queries, hits: [])
            throw error
        }
    }
}
