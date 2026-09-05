import Foundation
import PortavozCore
import StorageKit

/// The content-free mutation seam for a confirmation that has not crossed its
/// effect handoff. The proposal UUID identifies the durable receipt; arguments,
/// destinations, and idempotency keys never enter the control center.
public protocol WaitingSkillExecutionRevoking: Sendable {
    func cancelSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission
}

extension MeetingStore: WaitingSkillExecutionRevoking {}

public enum WaitingSkillExecutionRevocationOutcome: Equatable, Sendable {
    case revoked
    /// The run disappeared or crossed the handoff boundary before revocation
    /// committed. Both cases intentionally expose the same content-free truth.
    case unavailable
}

public enum WaitingSkillExecutionRevocationError: Error, Equatable, Sendable {
    case inconsistentAuthority
}

/// Revokes only a durable `confirmed` execution. Storage serializes this write
/// with `beginSkillExecution`: whichever commits first owns the outcome.
public struct RevokeWaitingSkillExecution: ApplicationUseCase {
    private let store: any WaitingSkillExecutionRevoking
    private let now: @Sendable () -> Date

    public init(
        store: any WaitingSkillExecutionRevoking,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ proposalID: UUID
    ) async throws -> WaitingSkillExecutionRevocationOutcome {
        try Task.checkCancellation()
        switch try await store.cancelSkillExecution(
            proposalID: proposalID,
            at: now()
        ) {
        case .alreadySettled(let record)
            where record.proposalID == proposalID && record.state == .dismissed:
            return .revoked
        case .rejected(.unknownExecution), .rejected(.illegalTransition):
            return .unavailable
        case .admitted, .alreadySettled, .rejected:
            throw WaitingSkillExecutionRevocationError.inconsistentAuthority
        }
    }
}
