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

/// One transient quality observation. It exposes only current semantic segment
/// identities and explainable Core proposals; it cannot confirm or persist a
/// link and is not composed into the app.
public struct CommitmentLinkSuggestionObservation: Sendable, Equatable {
    public let semanticHitSegmentIDs: [UUID]
    public let suggestions: [CommitmentLinkSuggestion]

    public init(
        semanticHitSegmentIDs: [UUID],
        suggestions: [CommitmentLinkSuggestion]
    ) {
        self.semanticHitSegmentIDs = semanticHitSegmentIDs
        self.suggestions = suggestions
    }
}

public enum ObserveCommitmentLinkSuggestionsError: Error, Sendable, Equatable {
    case invalidCandidateText
    case semanticUnavailable
    case invalidQueryVector
    case invalidSemanticEvidence
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
        let semanticHits = try await semanticHits(for: text)
        let segmentIDs = semanticHits.map(\.segmentID)
        guard segmentIDs.count <= CommitmentLinkSuggestionPolicy.maximumSemanticHitCount,
              Set(segmentIDs).count == segmentIDs.count
        else { throw ObserveCommitmentLinkSuggestionsError.invalidSemanticEvidence }

        return CommitmentLinkSuggestionObservation(
            semanticHitSegmentIDs: segmentIDs,
            suggestions: CommitmentLinkSuggestionPolicy.suggestions(
                sourceMeetingID: request.sourceMeetingID,
                actionItemID: request.actionItemID,
                candidateAssignee: request.candidateAssignee,
                semanticHitSegmentIDs: segmentIDs,
                targets: targets))
    }

    private func semanticHits(for text: String) async throws -> [SearchHit] {
        try await runtime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { [semanticIndex] embedder in
            let profile = await embedder.semanticEmbeddingProfile()
            guard profile.isValid,
                  let vector = try await embedder.vectors(for: [text]).first,
                  vector.count == profile.vectorDimension,
                  vector.allSatisfy(\.isFinite)
            else { throw ObserveCommitmentLinkSuggestionsError.invalidQueryVector }
            return try await semanticIndex.search(
                vector,
                profile: profile,
                limit: CommitmentLinkSuggestionPolicy.maximumSemanticHitCount)
        }
    }
}
