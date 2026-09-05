import Foundation
import PortavozCore

/// A content-free proposal for a semantic-boundary retrieval experiment.
/// Admission never builds chunks, loads a model, writes storage, or grants
/// product-serving authority.
public struct RetrievalSemanticBoundaryProposal: Equatable, Sendable {
    public enum Scope: String, Equatable, Sendable {
        case benchmarkOnly = "benchmark-only"
        case productServing = "product-serving"
    }

    public enum CanonicalUnit: String, Equatable, Sendable {
        case completeTurn = "complete-turn"
        case sentenceFragment = "sentence-fragment"
    }

    public enum SourceReuse: String, Equatable, Sendable {
        case nonOverlapping = "non-overlapping"
        case overlapping
    }

    public enum ActorTopology: String, Equatable, Sendable {
        case preserved
        case flattened
    }

    public struct ResourceBounds: Equatable, Sendable {
        public let maximumTurns: Int
        public let maximumCharacters: Int
        public let maximumDuration: TimeInterval
        public let maximumGap: TimeInterval

        public init(
            maximumTurns: Int,
            maximumCharacters: Int,
            maximumDuration: TimeInterval,
            maximumGap: TimeInterval
        ) {
            self.maximumTurns = maximumTurns
            self.maximumCharacters = maximumCharacters
            self.maximumDuration = maximumDuration
            self.maximumGap = maximumGap
        }

        public static let conversationWindowCeiling = ResourceBounds(
            maximumTurns: RetrievalConversationWindowChunker.maximumTurns,
            maximumCharacters:
                RetrievalConversationWindowChunker.maximumCharacters,
            maximumDuration:
                RetrievalConversationWindowChunker.maximumDuration,
            maximumGap: RetrievalConversationWindowChunker.maximumGap)
    }

    public struct LanguageProfile: Equatable, Sendable {
        public let language: String
        public let profile: SemanticEmbeddingProfile
        public let minimumCosineSimilarity: Double

        public init(
            language: String,
            profile: SemanticEmbeddingProfile,
            minimumCosineSimilarity: Double
        ) {
            self.language = language
            self.profile = profile
            self.minimumCosineSimilarity = minimumCosineSimilarity
        }
    }

    /// A shared space permits cross-language comparisons. Partitioned spaces
    /// make every language transition a boundary and compare only within the
    /// exact language-specific profile.
    public enum EmbeddingSpace: Equatable, Sendable {
        case shared(
            profile: SemanticEmbeddingProfile,
            supportedLanguages: [String],
            minimumCosineSimilarity: Double)
        case partitionedByLanguage([LanguageProfile])
    }

    public enum BoundarySignal: Equatable, Sendable {
        /// Natural Language sentence tokenization has no model/revision
        /// identity suitable for a cross-host retrieval candidate.
        case operatingSystemSentenceTokenizer
        case semanticSimilarity(embeddingSpace: EmbeddingSpace)
    }

    public let candidateIdentifier: String
    public let candidateRevision: Int
    public let scope: Scope
    public let canonicalUnit: CanonicalUnit
    public let sourceReuse: SourceReuse
    public let actorTopology: ActorTopology
    public let resourceBounds: ResourceBounds
    public let boundarySignal: BoundarySignal

    public init(
        candidateIdentifier: String,
        candidateRevision: Int,
        scope: Scope,
        canonicalUnit: CanonicalUnit,
        sourceReuse: SourceReuse,
        actorTopology: ActorTopology,
        resourceBounds: ResourceBounds,
        boundarySignal: BoundarySignal
    ) {
        self.candidateIdentifier = candidateIdentifier
        self.candidateRevision = candidateRevision
        self.scope = scope
        self.canonicalUnit = canonicalUnit
        self.sourceReuse = sourceReuse
        self.actorTopology = actorTopology
        self.resourceBounds = resourceBounds
        self.boundarySignal = boundarySignal
    }
}

public struct RetrievalSemanticBoundaryAdmission: Equatable, Sendable {
    public let contractVersion: String
    public let candidateIdentifier: String
    public let candidateRevision: Int
    public let scope: RetrievalSemanticBoundaryProposal.Scope
    /// Stable SHA-256 over policy/model/resource identity only. Transcript or
    /// query content never enters this value.
    public let proposalFingerprint: String
}

public enum RetrievalSemanticBoundaryPreflightError:
    Error, Equatable, LocalizedError {
    case invalidCandidateIdentifier
    case invalidCandidateRevision
    case productServingNotAllowed
    case canonicalSourceFragmentationNotRepresentable
    case overlappingSourcesNotAllowed
    case actorTopologyMustBePreserved
    case invalidResourceBounds
    case resourceBoundsExceedComparableCandidate
    case unversionedBoundarySignal
    case invalidEmbeddingProfile
    case invalidCosineThreshold
    case tooManyLanguages
    case invalidLanguage(String)
    case duplicateLanguage(String)
    case missingRequiredLanguage(String)
    case reusedPartitionedProfile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCandidateIdentifier:
            "semantic-boundary candidates require a lowercase stable identifier"
        case .invalidCandidateRevision:
            "semantic-boundary candidates require a positive revision"
        case .productServingNotAllowed:
            "semantic-boundary preflight grants benchmark authority only"
        case .canonicalSourceFragmentationNotRepresentable:
            "schema 2 cannot represent repeated fragments of one canonical source"
        case .overlappingSourcesNotAllowed:
            "semantic-boundary candidates cannot repeat canonical sources"
        case .actorTopologyMustBePreserved:
            "semantic-boundary candidates must retain ordered actor turns"
        case .invalidResourceBounds:
            "semantic-boundary sizes and duration must be positive; gap must be nonnegative"
        case .resourceBoundsExceedComparableCandidate:
            "semantic-boundary append bounds cannot exceed the conversation-window ceiling"
        case .unversionedBoundarySignal:
            "semantic-boundary candidates require a versioned model profile"
        case .invalidEmbeddingProfile:
            "semantic-boundary candidates require a valid embedding profile"
        case .invalidCosineThreshold:
            "semantic-boundary cosine similarity must be finite and within -1...1"
        case .tooManyLanguages:
            "semantic-boundary candidates support at most 16 language profiles"
        case .invalidLanguage(let language):
            "invalid semantic-boundary language: \(language)"
        case .duplicateLanguage(let language):
            "duplicate semantic-boundary language: \(language)"
        case .missingRequiredLanguage(let language):
            "semantic-boundary candidate is missing required language: \(language)"
        case .reusedPartitionedProfile(let language):
            "partitioned semantic spaces require a distinct profile for \(language)"
        }
    }
}

/// Fail-closed admission for the SEARCH-4b semantic-boundary candidate. This
/// deliberately answers whether a proposal is safe to benchmark, not whether
/// its retrieval quality is good enough to ship.
public enum RetrievalSemanticBoundaryPreflight {
    public static let contractVersion = "semantic-boundary-preflight-v1"
    public static let requiredLanguages = ["en", "es"]
    public static let maximumLanguageCount = 16
    public static let maximumCandidateIdentifierLength = 64

    public static func admit(
        _ proposal: RetrievalSemanticBoundaryProposal
    ) throws -> RetrievalSemanticBoundaryAdmission {
        guard validIdentifier(proposal.candidateIdentifier) else {
            throw RetrievalSemanticBoundaryPreflightError
                .invalidCandidateIdentifier
        }
        guard proposal.candidateRevision > 0 else {
            throw RetrievalSemanticBoundaryPreflightError
                .invalidCandidateRevision
        }
        guard proposal.scope == .benchmarkOnly else {
            throw RetrievalSemanticBoundaryPreflightError
                .productServingNotAllowed
        }
        guard proposal.canonicalUnit == .completeTurn else {
            throw RetrievalSemanticBoundaryPreflightError
                .canonicalSourceFragmentationNotRepresentable
        }
        guard proposal.sourceReuse == .nonOverlapping else {
            throw RetrievalSemanticBoundaryPreflightError
                .overlappingSourcesNotAllowed
        }
        guard proposal.actorTopology == .preserved else {
            throw RetrievalSemanticBoundaryPreflightError
                .actorTopologyMustBePreserved
        }
        try validate(proposal.resourceBounds)
        let signalIdentity = try boundarySignalIdentity(proposal.boundarySignal)
        let bounds = proposal.resourceBounds
        let fingerprint = OperationFingerprint.make(
            version: contractVersion,
            components: [
                proposal.candidateIdentifier,
                String(proposal.candidateRevision),
                proposal.scope.rawValue,
                proposal.canonicalUnit.rawValue,
                proposal.sourceReuse.rawValue,
                proposal.actorTopology.rawValue,
                String(bounds.maximumTurns),
                String(bounds.maximumCharacters),
                canonicalBitPattern(bounds.maximumDuration),
                canonicalBitPattern(bounds.maximumGap)
            ] + signalIdentity)
        return RetrievalSemanticBoundaryAdmission(
            contractVersion: contractVersion,
            candidateIdentifier: proposal.candidateIdentifier,
            candidateRevision: proposal.candidateRevision,
            scope: proposal.scope,
            proposalFingerprint: fingerprint)
    }

    private static func validate(
        _ bounds: RetrievalSemanticBoundaryProposal.ResourceBounds
    ) throws {
        guard bounds.maximumTurns >= 2,
              bounds.maximumCharacters > 0,
              bounds.maximumDuration.isFinite,
              bounds.maximumDuration > 0,
              bounds.maximumGap.isFinite,
              bounds.maximumGap >= 0
        else {
            throw RetrievalSemanticBoundaryPreflightError.invalidResourceBounds
        }
        let ceiling = RetrievalSemanticBoundaryProposal.ResourceBounds
            .conversationWindowCeiling
        guard bounds.maximumTurns <= ceiling.maximumTurns,
              bounds.maximumCharacters <= ceiling.maximumCharacters,
              bounds.maximumDuration <= ceiling.maximumDuration,
              bounds.maximumGap <= ceiling.maximumGap
        else {
            throw RetrievalSemanticBoundaryPreflightError
                .resourceBoundsExceedComparableCandidate
        }
    }

    private static func boundarySignalIdentity(
        _ signal: RetrievalSemanticBoundaryProposal.BoundarySignal
    ) throws -> [String] {
        switch signal {
        case .operatingSystemSentenceTokenizer:
            throw RetrievalSemanticBoundaryPreflightError
                .unversionedBoundarySignal
        case .semanticSimilarity(let embeddingSpace):
            return ["cosine-similarity"]
                + (try embeddingSpaceIdentity(embeddingSpace))
        }
    }

    private static func embeddingSpaceIdentity(
        _ space: RetrievalSemanticBoundaryProposal.EmbeddingSpace
    ) throws -> [String] {
        switch space {
        case .shared(
            let profile,
            let supportedLanguages,
            let minimumCosineSimilarity
        ):
            guard profile.isValid else {
                throw RetrievalSemanticBoundaryPreflightError
                    .invalidEmbeddingProfile
            }
            let languages = try normalizedUniqueLanguages(supportedLanguages)
            try requireBilingualCoverage(languages)
            return [
                "shared-vector-space",
                profile.fingerprint,
                try thresholdIdentity(minimumCosineSimilarity),
                languages.joined(separator: ",")
            ]
        case .partitionedByLanguage(let languageProfiles):
            guard languageProfiles.count <= maximumLanguageCount else {
                throw RetrievalSemanticBoundaryPreflightError.tooManyLanguages
            }
            var byLanguage: [
                String: RetrievalSemanticBoundaryProposal.LanguageProfile
            ] = [:]
            var profileOwners: [String: String] = [:]
            for languageProfile in languageProfiles {
                let language = try normalizedLanguage(languageProfile.language)
                guard languageProfile.profile.isValid else {
                    throw RetrievalSemanticBoundaryPreflightError
                        .invalidEmbeddingProfile
                }
                guard byLanguage.updateValue(
                    languageProfile,
                    forKey: language) == nil
                else {
                    throw RetrievalSemanticBoundaryPreflightError
                        .duplicateLanguage(language)
                }
                let fingerprint = languageProfile.profile.fingerprint
                if profileOwners[fingerprint] != nil {
                    throw RetrievalSemanticBoundaryPreflightError
                        .reusedPartitionedProfile(language)
                }
                profileOwners[fingerprint] = language
                _ = try thresholdIdentity(
                    languageProfile.minimumCosineSimilarity)
            }
            let languages = byLanguage.keys.sorted()
            try requireBilingualCoverage(languages)
            let identities = try byLanguage.sorted { $0.key < $1.key }.map {
                let threshold = try thresholdIdentity(
                    $0.value.minimumCosineSimilarity)
                return "\($0.key):\($0.value.profile.fingerprint):\(threshold)"
            }
            return ["partitioned-at-language-transition"] + identities
        }
    }

    private static func normalizedUniqueLanguages(
        _ values: [String]
    ) throws -> [String] {
        guard values.count <= maximumLanguageCount else {
            throw RetrievalSemanticBoundaryPreflightError.tooManyLanguages
        }
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let language = try normalizedLanguage(value)
            guard seen.insert(language).inserted else {
                throw RetrievalSemanticBoundaryPreflightError
                    .duplicateLanguage(language)
            }
            result.append(language)
        }
        return result.sorted()
    }

    private static func normalizedLanguage(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard (2...3).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({
                  (UnicodeScalar("a").value...UnicodeScalar("z").value)
                      .contains($0.value)
              })
        else {
            throw RetrievalSemanticBoundaryPreflightError.invalidLanguage(value)
        }
        return normalized
    }

    private static func requireBilingualCoverage(
        _ languages: [String]
    ) throws {
        let available = Set(languages)
        for language in requiredLanguages where !available.contains(language) {
            throw RetrievalSemanticBoundaryPreflightError
                .missingRequiredLanguage(language)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count <= maximumCandidateIdentifierLength,
              let first = value.unicodeScalars.first,
              (UnicodeScalar("a").value...UnicodeScalar("z").value)
                .contains(first.value),
              !value.hasSuffix("-"),
              !value.contains("--")
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (UnicodeScalar("a").value...UnicodeScalar("z").value)
                .contains(scalar.value)
                || (UnicodeScalar("0").value...UnicodeScalar("9").value)
                    .contains(scalar.value)
                || scalar == "-"
        }
    }

    private static func canonicalBitPattern(_ value: Double) -> String {
        String((value == 0 ? 0 : value).bitPattern)
    }

    private static func thresholdIdentity(_ value: Double) throws -> String {
        guard value.isFinite, (-1.0...1.0).contains(value) else {
            throw RetrievalSemanticBoundaryPreflightError
                .invalidCosineThreshold
        }
        return canonicalBitPattern(value)
    }
}
