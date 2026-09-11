import Foundation

/// One bounded, storage-independent context for evaluating whether a current
/// generated ActionItem may refer to an existing open commitment. These values
/// are transient and can never mutate commitment continuity.
public struct CommitmentLinkSuggestionTarget: Sendable, Equatable {
    public let commitment: Commitment
    public let sourceMeetingIDs: [MeetingID]
    public let evidenceSegmentIDs: [UUID]

    public init(
        commitment: Commitment,
        sourceMeetingIDs: [MeetingID],
        evidenceSegmentIDs: [UUID]
    ) {
        self.commitment = commitment
        self.sourceMeetingIDs = sourceMeetingIDs
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

/// Explainable proposal only. The user must still cross the explicit link
/// confirmation boundary before any source history is appended.
public struct CommitmentLinkSuggestion: Sendable, Equatable, Identifiable {
    public var id: CommitmentID { commitment.id }

    public let commitment: Commitment
    public let sourceMeetingID: MeetingID
    public let actionItemID: UUID
    public let assignee: CommitmentAssignee
    public let matchedEvidenceSegmentIDs: [UUID]
    /// One-based position in the caller's authoritative semantic result list.
    public let bestSemanticRank: Int

    public init(
        commitment: Commitment,
        sourceMeetingID: MeetingID,
        actionItemID: UUID,
        assignee: CommitmentAssignee,
        matchedEvidenceSegmentIDs: [UUID],
        bestSemanticRank: Int
    ) {
        self.commitment = commitment
        self.sourceMeetingID = sourceMeetingID
        self.actionItemID = actionItemID
        self.assignee = assignee
        self.matchedEvidenceSegmentIDs = matchedEvidenceSegmentIDs
        self.bestSemanticRank = bestSemanticRank
    }
}

/// Conservative non-serving ranker over already-authoritative evidence.
///
/// It requires both an ordered semantic evidence intersection and exact typed
/// assignee equality. Unknown, unassigned, conflicting, stale, closed, or
/// same-meeting contexts abstain. Similarity thresholds remain deliberately
/// outside this policy until a cross-meeting benchmark earns one.
public enum CommitmentLinkSuggestionPolicy {
    public static let maximumSemanticHitCount = 20
    public static let maximumTargetCount = 200
    public static let maximumRelatedRowCount = 20
    public static let maximumSuggestionCount = 3

    public static func suggestions(
        sourceMeetingID: MeetingID,
        actionItemID: UUID,
        candidateAssignee: CommitmentAssignee?,
        semanticHitSegmentIDs: [UUID],
        targets: [CommitmentLinkSuggestionTarget],
        limit: Int = maximumSuggestionCount
    ) -> [CommitmentLinkSuggestion] {
        guard (1...maximumSuggestionCount).contains(limit),
              semanticHitSegmentIDs.count <= maximumSemanticHitCount,
              targets.count <= maximumTargetCount,
              allUnique(semanticHitSegmentIDs),
              allUnique(targets.map(\.commitment.id)),
              let candidateAssignee,
              candidateAssignee != .unassigned
        else { return [] }

        let semanticRanks = Dictionary(
            uniqueKeysWithValues: semanticHitSegmentIDs.enumerated().map {
                ($0.element, $0.offset + 1)
            })
        guard !semanticRanks.isEmpty else { return [] }

        let suggestions = targets.compactMap { target -> CommitmentLinkSuggestion? in
            guard isValid(target),
                  target.commitment.assignee == candidateAssignee,
                  !target.sourceMeetingIDs.contains(sourceMeetingID)
            else { return nil }
            let matched = target.evidenceSegmentIDs
                .compactMap { segmentID in
                    semanticRanks[segmentID].map { (segmentID, $0) }
                }
                .sorted { lhs, rhs in lhs.1 < rhs.1 }
            guard let first = matched.first else { return nil }
            return CommitmentLinkSuggestion(
                commitment: target.commitment,
                sourceMeetingID: sourceMeetingID,
                actionItemID: actionItemID,
                assignee: candidateAssignee,
                matchedEvidenceSegmentIDs: matched.map(\.0),
                bestSemanticRank: first.1)
        }
        return Array(suggestions.sorted(by: precedes).prefix(limit))
    }

    private static func isValid(_ target: CommitmentLinkSuggestionTarget) -> Bool {
        target.commitment.status == .confirmed
            && target.commitment.deletedAt == nil
            && !target.commitment.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            && target.commitment.createdAt.timeIntervalSinceReferenceDate.isFinite
            && target.commitment.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && target.commitment.updatedAt >= target.commitment.createdAt
            && (target.commitment.dueAt?
                .timeIntervalSinceReferenceDate.isFinite ?? true)
            && target.sourceMeetingIDs.count <= maximumRelatedRowCount
            && target.evidenceSegmentIDs.count <= maximumRelatedRowCount
            && allUnique(target.sourceMeetingIDs)
            && allUnique(target.evidenceSegmentIDs)
    }

    private static func precedes(
        _ lhs: CommitmentLinkSuggestion,
        _ rhs: CommitmentLinkSuggestion
    ) -> Bool {
        if lhs.bestSemanticRank != rhs.bestSemanticRank {
            return lhs.bestSemanticRank < rhs.bestSemanticRank
        }
        if lhs.matchedEvidenceSegmentIDs.count != rhs.matchedEvidenceSegmentIDs.count {
            return lhs.matchedEvidenceSegmentIDs.count > rhs.matchedEvidenceSegmentIDs.count
        }
        return lhs.commitment.id.rawValue.uuidString
            < rhs.commitment.id.rawValue.uuidString
    }

    private static func allUnique<Element: Hashable>(_ values: [Element]) -> Bool {
        Set(values).count == values.count
    }
}
