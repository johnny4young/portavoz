import Foundation

/// One reversible user choice about whether a generated ActionItem should
/// remain in the confirmation inbox. This never stores generated text or
/// promotes the ActionItem into commitment truth.
public enum CommitmentReviewDisposition: String, Codable, CaseIterable, Sendable {
    case dismissed
    case deferred
}

public struct CommitmentReviewDecision: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { actionItemID }

    public let actionItemID: UUID
    public let disposition: CommitmentReviewDisposition
    public let revisitAt: Date?
    public let updatedAt: Date

    public init(
        actionItemID: UUID,
        disposition: CommitmentReviewDisposition,
        revisitAt: Date? = nil,
        updatedAt: Date
    ) {
        self.actionItemID = actionItemID
        self.disposition = disposition
        self.revisitAt = revisitAt
        self.updatedAt = updatedAt
    }
}

/// Storage-independent state needed to reconcile one current generated source
/// with review feedback or a confirmed continuity aggregate.
public struct CommitmentReviewState: Equatable, Sendable, Identifiable {
    public var id: UUID { actionItemID }

    public let actionItemID: UUID
    public let decision: CommitmentReviewDecision?
    public let commitment: Commitment?

    public init(
        actionItemID: UUID,
        decision: CommitmentReviewDecision? = nil,
        commitment: Commitment? = nil
    ) {
        self.actionItemID = actionItemID
        self.decision = decision
        self.commitment = commitment
    }
}

public enum CommitmentReviewValidationError: Error, Equatable, Sendable {
    case invalidDecision(UUID)
    case conflictingState(UUID)
}

public enum CommitmentReviewPolicy {
    public static func validate(_ decision: CommitmentReviewDecision) throws {
        guard decision.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              decision.revisitAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else { throw CommitmentReviewValidationError.invalidDecision(decision.actionItemID) }

        switch decision.disposition {
        case .dismissed:
            guard decision.revisitAt == nil else {
                throw CommitmentReviewValidationError.invalidDecision(decision.actionItemID)
            }
        case .deferred:
            guard let revisitAt = decision.revisitAt,
                  revisitAt > decision.updatedAt
            else {
                throw CommitmentReviewValidationError.invalidDecision(decision.actionItemID)
            }
        }
    }

    public static func validate(_ state: CommitmentReviewState) throws {
        guard state.decision == nil || state.commitment == nil else {
            throw CommitmentReviewValidationError.conflictingState(state.actionItemID)
        }
        if let decision = state.decision {
            guard decision.actionItemID == state.actionItemID else {
                throw CommitmentReviewValidationError.invalidDecision(state.actionItemID)
            }
            try validate(decision)
        }
    }

    /// A deferred source becomes reviewable again at its exact local date.
    public static func isPending(
        _ state: CommitmentReviewState,
        at date: Date
    ) -> Bool {
        guard state.commitment == nil else { return false }
        guard let decision = state.decision else { return true }
        switch decision.disposition {
        case .dismissed:
            return false
        case .deferred:
            return decision.revisitAt.map { $0 <= date } ?? false
        }
    }
}
