import ApplicationKit
import Foundation
import NaturalLanguage
import PortavozCore

enum CLIAppleSentenceBoundaryEmbeddingError:
    Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidRuntimeProfile(String)
    case unsupportedLanguage(String)
    case vectorUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let language):
            "Apple sentence embeddings are unavailable for \(language)"
        case .invalidRuntimeProfile(let language):
            "Apple sentence embedding identity is invalid for \(language)"
        case .unsupportedLanguage(let language):
            "semantic-boundary language is unsupported: \(language)"
        case .vectorUnavailable(let language):
            "Apple sentence embedding could not vectorize \(language) text"
        }
    }
}

/// CLI-only outer adapter for D351. It selects each exact current Apple
/// sentence-embedding revision once and never requests or downloads assets.
actor CLIAppleSentenceBoundaryEmbedding:
    RetrievalSemanticBoundaryEmbedding {
    static let candidateIdentifier = "apple-sentence-semantic-boundary"
    static let candidateRevision = 1
    static let englishMinimumCosineSimilarity = 0.60
    static let spanishMinimumCosineSimilarity = 0.75

    private struct Model {
        let embedding: NLEmbedding
        let profile: SemanticEmbeddingProfile
    }

    private let models: [String: Model]
    private let proposal: RetrievalSemanticBoundaryProposal

    init() throws {
        let english = try Self.model(
            language: .english,
            code: "en")
        let spanish = try Self.model(
            language: .spanish,
            code: "es")
        let proposal = Self.proposal(
            englishProfile: english.profile,
            spanishProfile: spanish.profile)
        _ = try RetrievalSemanticBoundaryPreflight.admit(proposal)
        self.models = ["en": english, "es": spanish]
        self.proposal = proposal
    }

    func boundaryProposal() -> RetrievalSemanticBoundaryProposal {
        proposal
    }

    func vector(
        for text: String,
        language: String
    ) throws -> RetrievalSemanticBoundaryVector {
        guard let model = models[language] else {
            throw CLIAppleSentenceBoundaryEmbeddingError
                .unsupportedLanguage(language)
        }
        guard let values = model.embedding.vector(for: text) else {
            throw CLIAppleSentenceBoundaryEmbeddingError
                .vectorUnavailable(language)
        }
        let floats = values.map(Float.init)
        guard floats.count == model.profile.vectorDimension,
              floats.allSatisfy(\.isFinite)
        else {
            throw CLIAppleSentenceBoundaryEmbeddingError
                .vectorUnavailable(language)
        }
        return RetrievalSemanticBoundaryVector(
            language: language,
            profileFingerprint: model.profile.fingerprint,
            values: floats)
    }

    static func proposal(
        englishProfile: SemanticEmbeddingProfile,
        spanishProfile: SemanticEmbeddingProfile
    ) -> RetrievalSemanticBoundaryProposal {
        RetrievalSemanticBoundaryProposal(
            candidateIdentifier: candidateIdentifier,
            candidateRevision: candidateRevision,
            scope: .benchmarkOnly,
            canonicalUnit: .completeTurn,
            sourceReuse: .nonOverlapping,
            actorTopology: .preserved,
            resourceBounds: .conversationWindowCeiling,
            boundarySignal: .semanticSimilarity(
                embeddingSpace: .partitionedByLanguage([
                    .init(
                        language: "en",
                        profile: englishProfile,
                        minimumCosineSimilarity:
                            englishMinimumCosineSimilarity),
                    .init(
                        language: "es",
                        profile: spanishProfile,
                        minimumCosineSimilarity:
                            spanishMinimumCosineSimilarity)
                ])))
    }

    static func profile(
        language: String,
        revision: Int,
        dimension: Int
    ) -> SemanticEmbeddingProfile {
        SemanticEmbeddingProfile(
            modelIdentifier:
                "apple.naturallanguage.nlembedding.sentence.\(language)",
            modelRevision: revision,
            vectorDimension: dimension,
            pipelineIdentifier: "native-sentence-vector-cosine",
            pipelineRevision: 1,
            vectorSchemaVersion: 1)
    }

    private static func model(
        language: NLLanguage,
        code: String
    ) throws -> Model {
        let revision = NLEmbedding
            .currentSentenceEmbeddingRevision(for: language)
        guard revision > 0,
              NLEmbedding.supportedSentenceEmbeddingRevisions(for: language)
                .contains(revision),
              let embedding = NLEmbedding.sentenceEmbedding(
                for: language,
                revision: revision)
        else {
            throw CLIAppleSentenceBoundaryEmbeddingError.unavailable(code)
        }
        let profile = profile(
            language: code,
            revision: revision,
            dimension: embedding.dimension)
        guard embedding.revision == revision,
              embedding.language == language,
              profile.isValid
        else {
            throw CLIAppleSentenceBoundaryEmbeddingError
                .invalidRuntimeProfile(code)
        }
        return Model(embedding: embedding, profile: profile)
    }
}
