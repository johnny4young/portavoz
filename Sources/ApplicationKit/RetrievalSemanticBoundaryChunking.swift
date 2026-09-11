import Foundation
import PortavozCore

/// One boundary vector whose language and exact embedding-space identity travel
/// beside its numeric values. Implementations never return transcript text.
public struct RetrievalSemanticBoundaryVector: Equatable, Sendable {
    public let language: String
    public let profileFingerprint: String
    public let values: [Float]

    public init(
        language: String,
        profileFingerprint: String,
        values: [Float]
    ) {
        self.language = language
        self.profileFingerprint = profileFingerprint
        self.values = values
    }
}

/// Benchmark-only vector adapter. ApplicationKit owns validation and chunk
/// policy; a disposable outer adapter owns the concrete model runtime.
public protocol RetrievalSemanticBoundaryEmbedding: Sendable {
    func boundaryProposal() async throws -> RetrievalSemanticBoundaryProposal

    func vector(
        for text: String,
        language: String
    ) async throws -> RetrievalSemanticBoundaryVector
}

/// Content-free counters for correction and resource characterization. They
/// reveal no text, source identity, vector, score, or model name.
public struct RetrievalSemanticBoundaryDiagnostics: Equatable, Sendable {
    public let turnCount: Int
    public let vectorizedTurnCount: Int
    public let joinedBoundaryCount: Int
    public let languageTransitionBoundaryCount: Int
    public let unavailableLanguageBoundaryCount: Int
    public let resourceBoundaryCount: Int
    public let similarityBoundaryCount: Int
}

public struct RetrievalSemanticBoundaryChunkingResult: Equatable, Sendable {
    public let admission: RetrievalSemanticBoundaryAdmission
    public let adapterIdentifier: String
    public let chunks: [RetrievalChunk]
    public let diagnostics: RetrievalSemanticBoundaryDiagnostics
}

public enum RetrievalSemanticBoundaryChunkingError:
    Error, Equatable, LocalizedError {
    case sharedEmbeddingSpaceNotImplemented
    case vectorLanguageMismatch(String)
    case vectorProfileMismatch(String)
    case invalidVector(String)

    public var errorDescription: String? {
        switch self {
        case .sharedEmbeddingSpaceNotImplemented:
            "the concrete semantic-boundary candidate requires partitioned language spaces"
        case .vectorLanguageMismatch(let language):
            "semantic-boundary vector returned the wrong language for \(language)"
        case .vectorProfileMismatch(let language):
            "semantic-boundary vector returned the wrong profile for \(language)"
        case .invalidVector(let language):
            "semantic-boundary vector is invalid for \(language)"
        }
    }
}

/// D351's concrete semantic policy. It compares only adjacent complete turns
/// inside one admitted language space and greedily emits non-overlapping units.
/// Product Ask, Library, storage, and semantic maintenance never compose it.
public enum RetrievalSemanticBoundaryChunker {
    public static let version = "semantic-boundary-v1"
    public static let adapterPrefix = "semantic-v1."

    public static func adapterIdentifier(
        for admission: RetrievalSemanticBoundaryAdmission
    ) -> String {
        adapterPrefix + admission.proposalFingerprint
    }

    public static func chunks(
        meetingID: MeetingID,
        transcriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        embedding: any RetrievalSemanticBoundaryEmbedding
    ) async throws -> RetrievalSemanticBoundaryChunkingResult {
        let proposal = try await embedding.boundaryProposal()
        let admission = try RetrievalSemanticBoundaryPreflight.admit(proposal)
        let configuration = try Configuration(proposal: proposal)
        let turns = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            correctionRevision: correctionRevision,
            segments: segments,
            speakers: speakers)
        let context = PublicationContext(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            correctionRevision: correctionRevision,
            admission: admission)
        let projection = try await projectedChunks(
            turns: turns,
            context: context,
            configuration: configuration,
            embedding: embedding)
        return RetrievalSemanticBoundaryChunkingResult(
            admission: admission,
            adapterIdentifier: adapterIdentifier(for: admission),
            chunks: projection.chunks,
            diagnostics: projection.counters.diagnostics)
    }

    private static func projectedChunks(
        turns: [RetrievalChunk],
        context: PublicationContext,
        configuration: Configuration,
        embedding: any RetrievalSemanticBoundaryEmbedding
    ) async throws -> (chunks: [RetrievalChunk], counters: Counters) {
        var chunks: [RetrievalChunk] = []
        chunks.reserveCapacity(turns.count)
        var draft: Draft?
        var counters = Counters(turnCount: turns.count)
        for turn in turns {
            try Task.checkCancellation()
            let language = supportedLanguage(
                for: turn,
                configuration: configuration)
            let vector = try await supportedVector(
                for: turn,
                language: language,
                configuration: configuration,
                embedding: embedding)
            counters.vectorizedTurnCount += vector == nil ? 0 : 1

            if var current = draft {
                let decision = try boundaryDecision(
                    draft: current,
                    nextTurn: turn,
                    nextLanguage: language,
                    nextVector: vector,
                    configuration: configuration)
                switch decision {
                case .join:
                    current.append(
                        turn,
                        language: language,
                        vector: vector)
                    draft = current
                    counters.joinedBoundaryCount += 1
                case .split(let reason):
                    chunks.append(makeChunk(
                        from: current,
                        meetingID: context.meetingID,
                        transcriptRevision: context.transcriptRevision,
                        correctionRevision: context.correctionRevision,
                        admission: context.admission))
                    counters.record(reason)
                    draft = Draft(
                        turn: turn,
                        language: language,
                        vector: vector)
                }
            } else {
                draft = Draft(
                    turn: turn,
                    language: language,
                    vector: vector)
            }
        }

        if let draft {
            chunks.append(makeChunk(
                from: draft,
                meetingID: context.meetingID,
                transcriptRevision: context.transcriptRevision,
                correctionRevision: context.correctionRevision,
                admission: context.admission))
        }
        return (chunks, counters)
    }

    private static func supportedLanguage(
        for turn: RetrievalChunk,
        configuration: Configuration
    ) -> String? {
        var languages: Set<String> = []
        for source in turn.sources {
            guard let rawLanguage = source.language else { return nil }
            let normalized = rawLanguage
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard let primary = normalized.split(separator: "-").first.map(String.init),
                  configuration.languages[primary] != nil
            else { return nil }
            languages.insert(primary)
        }
        guard languages.count == 1 else { return nil }
        return languages.first
    }

    private static func validatedVector(
        for turn: RetrievalChunk,
        language: String,
        configuration: LanguageConfiguration,
        embedding: any RetrievalSemanticBoundaryEmbedding
    ) async throws -> ValidatedVector {
        let vector = try await embedding.vector(
            for: turn.text,
            language: language)
        guard vector.language == language else {
            throw RetrievalSemanticBoundaryChunkingError
                .vectorLanguageMismatch(language)
        }
        guard vector.profileFingerprint == configuration.profile.fingerprint else {
            throw RetrievalSemanticBoundaryChunkingError
                .vectorProfileMismatch(language)
        }
        guard vector.values.count == configuration.profile.vectorDimension,
              vector.values.allSatisfy(\.isFinite)
        else {
            throw RetrievalSemanticBoundaryChunkingError.invalidVector(language)
        }
        let squaredMagnitude = vector.values.reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > 0 else {
            throw RetrievalSemanticBoundaryChunkingError.invalidVector(language)
        }
        return ValidatedVector(
            values: vector.values,
            magnitude: sqrt(squaredMagnitude))
    }

    private static func supportedVector(
        for turn: RetrievalChunk,
        language: String?,
        configuration: Configuration,
        embedding: any RetrievalSemanticBoundaryEmbedding
    ) async throws -> ValidatedVector? {
        guard let language,
              let languageConfiguration = configuration.languages[language]
        else { return nil }
        return try await validatedVector(
            for: turn,
            language: language,
            configuration: languageConfiguration,
            embedding: embedding)
    }

    private static func boundaryDecision(
        draft: Draft,
        nextTurn: RetrievalChunk,
        nextLanguage: String?,
        nextVector: ValidatedVector?,
        configuration: Configuration
    ) throws -> BoundaryDecision {
        guard let currentLanguage = draft.language,
              let nextLanguage,
              let currentVector = draft.lastVector,
              let nextVector
        else { return .split(.unavailableLanguage) }
        guard currentLanguage == nextLanguage else {
            return .split(.languageTransition)
        }
        guard draft.canAppend(
            nextTurn,
            bounds: configuration.resourceBounds)
        else { return .split(.resource) }
        let similarity = try cosineSimilarity(
            currentVector,
            nextVector,
            language: nextLanguage)
        guard let languageConfiguration = configuration.languages[nextLanguage],
              similarity >= languageConfiguration.minimumCosineSimilarity
        else { return .split(.similarity) }
        return .join
    }

    private static func cosineSimilarity(
        _ first: ValidatedVector,
        _ second: ValidatedVector,
        language: String
    ) throws -> Double {
        guard first.values.count == second.values.count else {
            throw RetrievalSemanticBoundaryChunkingError.invalidVector(language)
        }
        let dot = zip(first.values, second.values).reduce(0.0) {
            $0 + Double($1.0) * Double($1.1)
        }
        let similarity = dot / (first.magnitude * second.magnitude)
        guard similarity.isFinite else {
            throw RetrievalSemanticBoundaryChunkingError.invalidVector(language)
        }
        return min(1, max(-1, similarity))
    }

    private static func makeChunk(
        from draft: Draft,
        meetingID: MeetingID,
        transcriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision,
        admission: RetrievalSemanticBoundaryAdmission
    ) -> RetrievalChunk {
        let text = draft.turns.map(\.text).joined(separator: " ")
        let textFingerprint = OperationFingerprint.make(
            version: "retrieval-chunk-text-v1",
            components: [text])
        let sources = draft.turns.flatMap(\.sources)
        let turnBoundaries = draft.turns.flatMap(\.turns)
        let sourceFingerprint = OperationFingerprint.make(
            version: "retrieval-semantic-boundary-source-v1",
            components: [
                admission.proposalFingerprint,
                textFingerprint,
                draft.turns.map {
                    "\($0.id):\($0.sourceFingerprint)"
                }.joined(separator: "|")
            ])
        return RetrievalChunk(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            correctionRevision: correctionRevision,
            sources: sources,
            turns: turnBoundaries,
            text: text,
            normalizedTextFingerprint: textFingerprint,
            sourceFingerprint: sourceFingerprint,
            chunkerVersion: "\(version).\(admission.proposalFingerprint)")
    }

    private struct LanguageConfiguration: Sendable {
        let profile: SemanticEmbeddingProfile
        let minimumCosineSimilarity: Double
    }

    private struct PublicationContext: Sendable {
        let meetingID: MeetingID
        let transcriptRevision: Int
        let correctionRevision: TranscriptCorrectionRevision
        let admission: RetrievalSemanticBoundaryAdmission
    }

    private struct Configuration: Sendable {
        let resourceBounds: RetrievalSemanticBoundaryProposal.ResourceBounds
        let languages: [String: LanguageConfiguration]

        init(proposal: RetrievalSemanticBoundaryProposal) throws {
            guard case .semanticSimilarity(let space) = proposal.boundarySignal,
                  case .partitionedByLanguage(let profiles) = space
            else {
                throw RetrievalSemanticBoundaryChunkingError
                    .sharedEmbeddingSpaceNotImplemented
            }
            self.resourceBounds = proposal.resourceBounds
            self.languages = Dictionary(uniqueKeysWithValues: profiles.map {
                let language = $0.language
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
                return (
                    language,
                    LanguageConfiguration(
                        profile: $0.profile,
                        minimumCosineSimilarity: $0.minimumCosineSimilarity))
            })
        }
    }

    private struct ValidatedVector: Sendable {
        let values: [Float]
        let magnitude: Double
    }

    private enum BoundaryDecision {
        case join
        case split(BoundaryReason)
    }

    private enum BoundaryReason {
        case languageTransition
        case unavailableLanguage
        case resource
        case similarity
    }

    private struct Draft {
        private(set) var turns: [RetrievalChunk]
        private(set) var language: String?
        private(set) var lastVector: ValidatedVector?
        private(set) var characterCount: Int

        init(
            turn: RetrievalChunk,
            language: String?,
            vector: ValidatedVector?
        ) {
            self.turns = [turn]
            self.language = language
            self.lastVector = vector
            self.characterCount = turn.text.count
        }

        func canAppend(
            _ turn: RetrievalChunk,
            bounds: RetrievalSemanticBoundaryProposal.ResourceBounds
        ) -> Bool {
            guard turns.count < bounds.maximumTurns,
                  let first = turns.first,
                  let last = turns.last
            else { return false }
            let gap = turn.startTime - last.endTime
            let duration = turn.endTime - first.startTime
            return gap >= 0
                && gap <= bounds.maximumGap
                && duration <= bounds.maximumDuration
                && characterCount + 1 + turn.text.count
                    <= bounds.maximumCharacters
        }

        mutating func append(
            _ turn: RetrievalChunk,
            language: String?,
            vector: ValidatedVector?
        ) {
            characterCount += 1 + turn.text.count
            turns.append(turn)
            self.language = language
            self.lastVector = vector
        }
    }

    private struct Counters {
        let turnCount: Int
        var vectorizedTurnCount = 0
        var joinedBoundaryCount = 0
        var languageTransitionBoundaryCount = 0
        var unavailableLanguageBoundaryCount = 0
        var resourceBoundaryCount = 0
        var similarityBoundaryCount = 0

        mutating func record(_ reason: BoundaryReason) {
            switch reason {
            case .languageTransition:
                languageTransitionBoundaryCount += 1
            case .unavailableLanguage:
                unavailableLanguageBoundaryCount += 1
            case .resource:
                resourceBoundaryCount += 1
            case .similarity:
                similarityBoundaryCount += 1
            }
        }

        var diagnostics: RetrievalSemanticBoundaryDiagnostics {
            RetrievalSemanticBoundaryDiagnostics(
                turnCount: turnCount,
                vectorizedTurnCount: vectorizedTurnCount,
                joinedBoundaryCount: joinedBoundaryCount,
                languageTransitionBoundaryCount:
                    languageTransitionBoundaryCount,
                unavailableLanguageBoundaryCount:
                    unavailableLanguageBoundaryCount,
                resourceBoundaryCount: resourceBoundaryCount,
                similarityBoundaryCount: similarityBoundaryCount)
        }
    }
}
