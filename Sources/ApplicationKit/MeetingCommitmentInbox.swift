import Foundation
import PortavozCore

public struct CommitmentOwnerSuggestion: Equatable, Sendable {
    public let personID: PersonID
    public let displayName: String

    public init(personID: PersonID, displayName: String) {
        self.personID = personID
        self.displayName = displayName
    }
}

public enum CommitmentInboxStatus: Equatable, Sendable {
    case pending
    case deferred(until: Date)
    case dismissed
    case confirmed(Commitment)
}

/// Presentation-ready candidate derived from an immutable generated ActionItem.
/// It is never itself persisted and cannot create continuity without an
/// explicit confirmation request.
public struct CommitmentInboxCandidate: Sendable, Identifiable {
    public var id: UUID { actionItem.id }

    public let actionItem: ActionItem
    public let evidence: TranscriptEvidenceResolution
    public let suggestedOwner: CommitmentOwnerSuggestion?
    public let suggestedDueAt: Date?
    public let status: CommitmentInboxStatus
}

public extension MeetingReviewReadModel {
    func commitmentOwnerChoices() -> [CommitmentOwnerSuggestion] {
        var seen: Set<PersonID> = []
        return speakers.compactMap { speaker in
            guard let suggestion = Self.commitmentOwnerSuggestion(speaker),
                  seen.insert(suggestion.personID).inserted
            else { return nil }
            return suggestion
        }
    }

    func commitmentInboxCandidates(
        at date: Date = Date()
    ) -> [CommitmentInboxCandidate] {
        guard let summary else { return [] }
        let evidenceByItem = summary.draft.actionItemEvidence.reduce(
            into: [UUID: SummaryActionItemEvidence]()) { result, evidence in
                if result[evidence.actionItemID] == nil {
                    result[evidence.actionItemID] = evidence
                }
        }
        let stateByItem = commitmentReviewStates.reduce(
            into: [UUID: CommitmentReviewState]()) { result, state in
                if result[state.actionItemID] == nil {
                    result[state.actionItemID] = state
                }
        }
        let speakerByID = speakers.reduce(into: [SpeakerID: Speaker]()) { result, speaker in
            if result[speaker.id] == nil {
                result[speaker.id] = speaker
            }
        }

        return summary.draft.actionItems.compactMap { item in
            guard !item.isDone, let source = evidenceByItem[item.id] else { return nil }
            let evidence = summaryFreshness == .current
                ? source.resolveEvidence(
                    currentTranscriptRevision: meeting.transcriptRevision,
                    segments: segments)
                : TranscriptEvidenceResolution(status: .stale)
            let state = stateByItem[item.id]
            return CommitmentInboxCandidate(
                actionItem: item,
                evidence: evidence,
                suggestedOwner: item.ownerSpeakerID
                    .flatMap { speakerByID[$0] }
                    .flatMap(Self.commitmentOwnerSuggestion),
                // No production deadline extractor has passed COMMIT-0. The
                // confirmation surface may accept a user date but cannot
                // manufacture a suggestion from free text.
                suggestedDueAt: nil,
                status: Self.commitmentInboxStatus(state, at: date))
        }
    }

    private static func commitmentOwnerSuggestion(
        _ speaker: Speaker
    ) -> CommitmentOwnerSuggestion? {
        guard let personID = speaker.personID else { return nil }
        return CommitmentOwnerSuggestion(
            personID: personID,
            displayName: speaker.displayName ?? speaker.label)
    }

    private static func commitmentInboxStatus(
        _ state: CommitmentReviewState?,
        at date: Date
    ) -> CommitmentInboxStatus {
        if let commitment = state?.commitment {
            return .confirmed(commitment)
        }
        guard let decision = state?.decision else { return .pending }
        switch decision.disposition {
        case .dismissed:
            return .dismissed
        case .deferred:
            guard let revisitAt = decision.revisitAt, revisitAt > date else {
                return .pending
            }
            return .deferred(until: revisitAt)
        }
    }
}
