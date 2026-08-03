import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentLinkSuggestionTargetReading: Sendable {
    func commitmentLinkSuggestionTargets(
        limit: Int
    ) async throws -> [CommitmentLinkSuggestionTarget]
}

extension MeetingStore: CommitmentLinkSuggestionTargetReading {}

public struct ObserveCommitmentLinkSuggestionsRequest: Sendable, Equatable {
    public let sourceMeetingID: MeetingID
    public let actionItemID: UUID
    public let candidateText: String
    public let candidateAssignee: CommitmentAssignee

    public init(
        sourceMeetingID: MeetingID,
        actionItemID: UUID,
        candidateText: String,
        candidateAssignee: CommitmentAssignee
    ) {
        self.sourceMeetingID = sourceMeetingID
        self.actionItemID = actionItemID
        self.candidateText = candidateText
        self.candidateAssignee = candidateAssignee
    }
}

/// One profile-local semantic result retained only for quality measurement.
/// The score is exact cosine evidence, not an accepted relevance threshold.
public struct CommitmentLinkSemanticHit: Sendable, Equatable {
    public let segmentID: UUID
    public let similarity: Float

    public init(segmentID: UUID, similarity: Float) {
        self.segmentID = segmentID
        self.similarity = similarity
    }
}

/// One transient quality observation. It exposes profile-bound semantic
/// evidence and explainable Core proposals; it cannot confirm or persist a
/// link and is not composed into the app.
public struct CommitmentLinkSuggestionObservation: Sendable, Equatable {
    public let semanticProfileFingerprint: String
    public let semanticHits: [CommitmentLinkSemanticHit]
    public let suggestions: [CommitmentLinkSuggestion]

    public init(
        semanticProfileFingerprint: String,
        semanticHits: [CommitmentLinkSemanticHit],
        suggestions: [CommitmentLinkSuggestion]
    ) {
        self.semanticProfileFingerprint = semanticProfileFingerprint
        self.semanticHits = semanticHits
        self.suggestions = suggestions
    }

    public var semanticHitSegmentIDs: [UUID] {
        semanticHits.map(\.segmentID)
    }
}

public enum ObserveCommitmentLinkSuggestionsError: Error, Sendable, Equatable {
    case invalidCandidateText
    case semanticUnavailable
    case invalidQueryVector
    case invalidSemanticEvidence
    case invalidSemanticSimilarity
}

/// Non-serving product-path adapter used to measure cross-meeting retrieval and
/// domain admission before any suggestion becomes visible. It borrows the
/// installed embedding model without downloading assets, searches through the
/// existing authoritative semantic port, then delegates all admission to the
/// pure Core policy.
public struct ObserveCommitmentLinkSuggestions: ApplicationUseCase {
    public static let maximumCandidateTextLength = 2_000

    private let targetReader: any CommitmentLinkSuggestionTargetReading
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let semanticReadiness: ResolveSemanticCorpusReadiness
    private let semanticIndex: any SemanticIndexSearching

    public init(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        semanticReadiness: ResolveSemanticCorpusReadiness? = nil,
        semanticIndex: (any SemanticIndexSearching)? = nil,
        targetReader: (any CommitmentLinkSuggestionTargetReading)? = nil
    ) {
        self.targetReader = targetReader ?? store
        self.runtime = runtime
        self.semanticReadiness = semanticReadiness
            ?? ResolveSemanticCorpusReadiness(store: store, runtime: runtime)
        self.semanticIndex = semanticIndex
            ?? AccelerateExactSemanticIndex(store: store)
    }

    public func execute(
        _ request: ObserveCommitmentLinkSuggestionsRequest
    ) async throws -> CommitmentLinkSuggestionObservation {
        let text = request.candidateText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maximumCandidateTextLength
        else { throw ObserveCommitmentLinkSuggestionsError.invalidCandidateText }

        let readiness = try await semanticReadiness.current()
        guard readiness.canSearchPublishedVectors else {
            throw ObserveCommitmentLinkSuggestionsError.semanticUnavailable
        }
        let targets = try await targetReader.commitmentLinkSuggestionTargets(
            limit: CommitmentLinkSuggestionPolicy.maximumTargetCount)
        let semanticResult = try await semanticHits(for: text)
        let segmentIDs = semanticResult.hits.map(\.segmentID)
        guard segmentIDs.count <= CommitmentLinkSuggestionPolicy.maximumSemanticHitCount,
              Set(segmentIDs).count == segmentIDs.count
        else { throw ObserveCommitmentLinkSuggestionsError.invalidSemanticEvidence }
        let scoredHits = try Self.validatedSemanticHits(semanticResult.hits)

        return CommitmentLinkSuggestionObservation(
            semanticProfileFingerprint: semanticResult.profileFingerprint,
            semanticHits: scoredHits,
            suggestions: CommitmentLinkSuggestionPolicy.suggestions(
                sourceMeetingID: request.sourceMeetingID,
                actionItemID: request.actionItemID,
                candidateAssignee: request.candidateAssignee,
                semanticHitSegmentIDs: segmentIDs,
                targets: targets))
    }

    private func semanticHits(for text: String) async throws -> SemanticResult {
        try await runtime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { [semanticIndex] embedder in
            let profile = await embedder.semanticEmbeddingProfile()
            guard profile.isValid,
                  let vector = try await embedder.vectors(for: [text]).first,
                  vector.count == profile.vectorDimension,
                  vector.allSatisfy(\.isFinite)
            else { throw ObserveCommitmentLinkSuggestionsError.invalidQueryVector }
            let hits = try await semanticIndex.search(
                vector,
                profile: profile,
                limit: CommitmentLinkSuggestionPolicy.maximumSemanticHitCount)
            return SemanticResult(
                profileFingerprint: profile.fingerprint,
                hits: hits)
        }
    }

    private static func validatedSemanticHits(
        _ hits: [SearchHit]
    ) throws -> [CommitmentLinkSemanticHit] {
        var previousSimilarity = Float.infinity
        return try hits.map { hit in
            guard let rawSimilarity = hit.semanticSimilarity,
                  rawSimilarity.isFinite,
                  rawSimilarity >= -1.0001,
                  rawSimilarity <= 1.0001
            else {
                throw ObserveCommitmentLinkSuggestionsError.invalidSemanticSimilarity
            }
            let similarity = min(max(rawSimilarity, -1), 1)
            guard similarity <= previousSimilarity else {
                throw ObserveCommitmentLinkSuggestionsError.invalidSemanticSimilarity
            }
            previousSimilarity = similarity
            return CommitmentLinkSemanticHit(
                segmentID: hit.segmentID,
                similarity: similarity)
        }
    }

    private struct SemanticResult: Sendable {
        let profileFingerprint: String
        let hits: [SearchHit]
    }
}
