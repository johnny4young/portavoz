import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

struct AskQualityAttributionDocument: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "ask-quality-attribution"
    let outcome = "diagnostic-only"
    let observation: AskQualityObservationDocument
    let corpus: AskQualityCorpusEvidence
    let stages: [AskQualityStageEvidence]
}

struct AskQualityCorpusEvidence: Encodable, Sendable {
    let profile: SemanticEmbeddingProfile
    let profileFingerprint: String
    let projectedUnitCount: Int
    let embeddedRows: Int
    let excludedRows: Int
    let skippedRows: Int
    let invalidatedRows: Int
    let pendingRowsRemain: Bool
    let pausedByPolicy: Bool
    let embeddingResults: AskQualityVectorCounts
}

struct AskQualityVectorCounts: Encodable, Equatable, Sendable {
    var requestedTexts = 0
    var returnedVectors = 0
    var nonzeroFiniteVectors = 0
    var zeroVectors = 0
    var malformedVectors = 0
}

struct AskQualityStageEvidence: Encodable, Sendable {
    let queryID: String
    let lexical: [AskQualityHitObservation]
    /// Exact batch calls, with variant order and pre-fusion top-k preserved.
    /// Empty means the semantic-index boundary was not invoked, not failure.
    let semanticRequests: [AskQualitySemanticRequest]
}

struct AskQualitySemanticRequest: Encodable, Sendable {
    enum Outcome: String, Encodable, Sendable { case succeeded, failed }
    let outcome: Outcome
    let profileFingerprint: String
    let candidateLimit: Int
    let queryVectors: AskQualityVectorCounts
    let variants: [[AskQualityHitObservation]]
}

enum AskQualityAttributionError: Error, Equatable, LocalizedError {
    case downloadsForbidden
    case profileChanged
    case incompletePreparation
    case incompleteStages

    var errorDescription: String? {
        switch self {
        case .downloadsForbidden: "attribution requires installed assets; downloads are forbidden"
        case .profileChanged: "attribution embedding profile changed or is invalid"
        case .incompletePreparation: "attribution corpus preparation is incomplete"
        case .incompleteStages: "attribution stages do not match the completed query"
        }
    }
}

enum AskQualityAttributionBenchmark {
    static func run(
        fixture: AskQualityFixture,
        options: AskQualityBenchmarkOptions
    ) async throws -> AskQualityAttributionDocument {
        guard !options.allowAssetDownload else {
            throw AskQualityAttributionError.downloadsForbidden
        }
        return try await AskQualityWorkspace.withCorpus(
            fixture: fixture, retrievalUnit: options.retrievalUnit
        ) { context in
            let corpus = try await prepare(context)
            return try await observe(
                fixture: fixture, context: context, corpus: corpus,
                options: options)
        }
    }

    static func prepare(_ context: AskQualityWorkspace) async throws -> AskQualityCorpusEvidence {
        try await context.runtime.withPreparedEmbedding(allowAssetDownload: false) { embedder in
            let profile = await embedder.semanticEmbeddingProfile()
            guard profile.isValid else { throw AskQualityAttributionError.profileChanged }
            let measured = AskQualityMeasuredEmbedding(underlying: embedder, profile: profile)
            let result = try await IndexSemanticCorpus(store: context.store).all(
                using: measured, batchSize: 256)
            let currentProfile = await embedder.semanticEmbeddingProfile()
            guard currentProfile == profile else { throw AskQualityAttributionError.profileChanged }
            let pending = try await context.store.semanticIndexRequiresMaintenance(for: profile)
            let count = context.mapping.projectedUnitCount
            let vectors = await measured.counts
            guard !pending, !result.pausedByPolicy, result.skippedSegments == 0,
                  result.invalidatedSegments == 0,
                  result.embeddedSegments + result.excludedSegments == count,
                  vectors.requestedTexts == result.embeddedSegments,
                  vectors.returnedVectors == result.embeddedSegments,
                  vectors.malformedVectors == 0
            else { throw AskQualityAttributionError.incompletePreparation }
            return AskQualityCorpusEvidence(
                profile: profile, profileFingerprint: profile.fingerprint,
                projectedUnitCount: count, embeddedRows: result.embeddedSegments,
                excludedRows: result.excludedSegments, skippedRows: result.skippedSegments,
                invalidatedRows: result.invalidatedSegments, pendingRowsRemain: pending,
                pausedByPolicy: result.pausedByPolicy, embeddingResults: vectors)
        }
    }

    static func observe(
        fixture: AskQualityFixture,
        context: AskQualityWorkspace,
        corpus: AskQualityCorpusEvidence,
        options: AskQualityBenchmarkOptions,
        semanticIndex: (any SemanticIndexSearching)? = nil
    ) async throws -> AskQualityAttributionDocument {
        guard options.retrievalUnit.matches(adapter: context.mapping.adapter) else {
            throw AskQualityAttributionError.incompleteStages
        }
        let recorder = AskQualityStageRecorder(mapping: context.mapping)
        let measuredIndex = AskQualityMeasuredIndex(
            underlying: semanticIndex ?? AccelerateExactSemanticIndex(store: context.store),
            recorder: recorder, profile: corpus.profile)
        let retrieval = LocalAskMeetingRetrieval(
            store: context.store, queryExpander: AskQualityNoExpansion(),
            runtime: context.runtime, semanticIndex: measuredIndex)
        var queries: [AskQualityQueryObservation] = []
        var stages: [AskQualityStageEvidence] = []
        for query in fixture.queries {
            try Task.checkCancellation()
            await recorder.begin()
            let citations = try await AskPipelineTelemetry.disabled.measure(.evidence) { trace in
                try await retrieval.retrieve(
                    question: query.text, limit: 10, trace: trace,
                    onEvidence: { await recorder.record($0) })
            }
            let hits = try citations.map { try context.mapping.observation(for: $0) }
            stages.append(try await recorder.finish(queryID: query.id, finalHits: hits))
            queries.append(AskQualityQueryObservation(
                queryID: query.id, hits: hits, answer: AskQualityAnswerObservation()))
        }
        let profile = await context.runtime.semanticEmbeddingProfile()
        guard profile == corpus.profile else { throw AskQualityAttributionError.profileChanged }
        try Task.checkCancellation()
        return AskQualityAttributionDocument(
            observation: AskQualityObservationDocument(
                fixtureGeneration: fixture.generation, adapter: context.mapping.adapter,
                build: options.build, commit: options.commit, queries: queries),
            corpus: corpus, stages: stages)
    }
}

actor AskQualityMeasuredEmbedding: SemanticTextEmbedding {
    let underlying: any SemanticTextEmbedding
    let profile: SemanticEmbeddingProfile
    private(set) var counts = AskQualityVectorCounts()

    init(underlying: any SemanticTextEmbedding, profile: SemanticEmbeddingProfile) {
        self.underlying = underlying
        self.profile = profile
    }

    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile {
        await underlying.semanticEmbeddingProfile()
    }

    func vectors(for texts: [String]) async throws -> [[Float]] {
        let vectors = try await underlying.vectors(for: texts)
        let batch = AskQualityVectorCounts.measure(
            vectors, requested: texts.count, dimension: profile.vectorDimension)
        counts.requestedTexts += batch.requestedTexts
        counts.returnedVectors += batch.returnedVectors
        counts.nonzeroFiniteVectors += batch.nonzeroFiniteVectors
        counts.zeroVectors += batch.zeroVectors
        counts.malformedVectors += batch.malformedVectors
        return vectors
    }
}

extension AskQualityVectorCounts {
    static func measure(_ vectors: [[Float]], requested: Int, dimension: Int) -> Self {
        var result = Self(requestedTexts: requested, returnedVectors: vectors.count)
        for vector in vectors {
            if vector.count != dimension || !vector.allSatisfy(\.isFinite) {
                result.malformedVectors += 1
            } else if vector.allSatisfy({ $0 == 0 }) {
                result.zeroVectors += 1
            } else {
                result.nonzeroFiniteVectors += 1
            }
        }
        return result
    }
}
