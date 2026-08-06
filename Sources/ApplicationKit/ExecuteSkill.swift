import Foundation
import PortavozCore
import StorageKit

/// The durable claim a skill executor needs. Storage owns the real one; this
/// port keeps the use case testable and free of GRDB.
public protocol SkillExecutionClaiming: Sendable {
    func confirmSkillExecution(
        proposalID: UUID,
        skillID: String,
        skillVersion: Int,
        idempotencyKey: String,
        at now: Date
    ) async throws -> SkillExecutionAdmission

    func beginSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission

    func settleSkillExecution(
        proposalID: UUID,
        succeeded: Bool,
        failureCategory: FailureCategory?,
        at now: Date
    ) async throws -> SkillExecutionAdmission
}

extension MeetingStore: SkillExecutionClaiming {}

/// Performs one skill's actual effect. Everything platform-specific lives
/// behind this: the use case never learns what a reminder is.
public protocol SkillEffectPerforming: Sendable {
    func perform(_ proposal: SkillProposal) async throws
}

/// Why an execution did not reach its effect. Every case means nothing
/// happened outside Portavoz, except `failed`, which means the effect was
/// attempted and reported an outcome.
public enum SkillExecutionOutcome: Equatable, Sendable {
    case performed
    /// The effect was already claimed and settled. Includes a relaunch finding
    /// a run that was interrupted: the caller must reconcile, not repeat.
    case alreadySettled(SkillExecutionState)
    case refused(SkillAdmissionRefusal)
    case rejected(SkillExecutionRejection)
    case failed(FailureCategory)
}

public struct ExecuteSkillRequest: Sendable {
    public let proposal: SkillProposal
    public let isConfirmedByUser: Bool
    public let egressIsPermitted: Bool
    /// Stable for one intended effect, so a retry of the same intent claims the
    /// same slot instead of producing a second one.
    public let idempotencyKey: String

    public init(
        proposal: SkillProposal,
        isConfirmedByUser: Bool,
        egressIsPermitted: Bool,
        idempotencyKey: String
    ) {
        self.proposal = proposal
        self.isConfirmedByUser = isConfirmedByUser
        self.egressIsPermitted = egressIsPermitted
        self.idempotencyKey = idempotencyKey
    }
}

/// Composes the two decisions Band 8 separates on purpose: whether a skill
/// *may* run (D292, from its declaration and the user's confirmation) and
/// whether it *already has* (D293, from durable state).
///
/// The order is load-bearing. Admission runs first and, when it refuses,
/// nothing is written — a refused proposal leaves no trace to reconcile later.
/// The durable claim then happens strictly before the effect, so a crash
/// between them is recoverable as an interrupted run rather than an invisible
/// one.
public struct ExecuteSkill: ApplicationUseCase {
    private let claims: any SkillExecutionClaiming
    private let effects: [String: any SkillEffectPerforming]
    private let now: @Sendable () -> Date

    public init(
        claims: any SkillExecutionClaiming,
        effects: [String: any SkillEffectPerforming],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claims = claims
        self.effects = effects
        self.now = now
    }

    public func execute(
        _ request: ExecuteSkillRequest
    ) async throws -> SkillExecutionOutcome {
        let proposal = request.proposal
        switch SkillAdmissionPolicy.admit(
            proposal,
            isConfirmedByUser: request.isConfirmedByUser,
            egressIsPermitted: request.egressIsPermitted,
            at: now()
        ) {
        case .refused(let reason):
            return .refused(reason)
        case .admitted:
            break
        }

        // An unknown skill is refused before anything durable is written; a
        // claim with no way to perform it would be an execution that can never
        // settle.
        guard let effect = effects[proposal.definition.id] else {
            return .refused(.invalidDefinition)
        }

        switch try await claims.confirmSkillExecution(
            proposalID: proposal.id,
            skillID: proposal.definition.id,
            skillVersion: proposal.definition.version,
            idempotencyKey: request.idempotencyKey,
            at: now()
        ) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .admitted, .alreadySettled:
            // An existing claim is not by itself a reason to stop: a failed
            // execution is retryable. `beginSkillExecution` already encodes
            // exactly which states may proceed, so it stays the only place
            // that decides — duplicating that policy here is how the two
            // drift apart.
            break
        }

        switch try await claims.beginSkillExecution(
            proposalID: proposal.id,
            at: now()
        ) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .alreadySettled(let record):
            return .alreadySettled(record.state)
        case .admitted:
            break
        }

        do {
            try await effect.perform(proposal)
        } catch {
            let category = (error as? CategorizedFailure)?.category ?? .recoverable
            _ = try await claims.settleSkillExecution(
                proposalID: proposal.id,
                succeeded: false,
                failureCategory: category,
                at: now())
            return .failed(category)
        }

        _ = try await claims.settleSkillExecution(
            proposalID: proposal.id,
            succeeded: true,
            failureCategory: nil,
            at: now())
        return .performed
    }
}

/// An error that names its own category, so settlement records a typed
/// category instead of guessing one from a message.
public protocol CategorizedFailure: Error {
    var category: FailureCategory { get }
}
