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
        offerKey: String,
        idempotencyKey: String,
        at now: Date
    ) async throws -> SkillExecutionAdmission

    func beginSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission

    func cancelSkillExecution(
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
    /// Stable identity of the offer the user reviewed. This can be broader
    /// than one effect slot (for example a reusable export with one slot per
    /// destination), so it remains distinct from `idempotencyKey`.
    public let offerKey: String

    public init(
        proposal: SkillProposal,
        isConfirmedByUser: Bool,
        egressIsPermitted: Bool,
        offerKey: String,
        idempotencyKey: String
    ) {
        self.proposal = proposal
        self.isConfirmedByUser = isConfirmedByUser
        self.egressIsPermitted = egressIsPermitted
        self.offerKey = offerKey
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
    private let policy: any SkillExecutionPolicyReading
    private let effects: [String: any SkillEffectPerforming]
    private let now: @Sendable () -> Date

    public init(
        claims: any SkillExecutionClaiming,
        policy: any SkillExecutionPolicyReading,
        effects: [String: any SkillEffectPerforming],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claims = claims
        self.policy = policy
        self.effects = effects
        self.now = now
    }

    public func execute(
        _ request: ExecuteSkillRequest
    ) async throws -> SkillExecutionOutcome {
        // Cancellation before confirmation must be indistinguishable from the
        // user never authorizing the proposal: no durable claim, no effect.
        try Task.checkCancellation()
        let proposal = request.proposal
        // Re-read the durable switchboard for every attempt. A pane snapshot
        // or an already-open confirmation sheet is never authority to run.
        let executionPolicy = try await policy.skillExecutionPolicy()
        try Task.checkCancellation()
        switch SkillAdmissionPolicy.admit(
            proposal,
            isConfirmedByUser: request.isConfirmedByUser,
            egressIsPermitted: request.egressIsPermitted,
            executionPolicy: executionPolicy,
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

        if let outcome = try await confirmationOutcome(
            proposal: proposal,
            offerKey: request.offerKey,
            idempotencyKey: request.idempotencyKey
        ) {
            return outcome
        }

        try await checkCancellationBeforeHandoff(proposalID: proposal.id)

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

    private func confirmationOutcome(
        proposal: SkillProposal,
        offerKey: String,
        idempotencyKey: String
    ) async throws -> SkillExecutionOutcome? {
        switch try await claims.confirmSkillExecution(
            proposalID: proposal.id,
            skillID: proposal.definition.id,
            skillVersion: proposal.definition.version,
            offerKey: offerKey,
            idempotencyKey: idempotencyKey,
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
            return nil
        }
    }

    /// Confirmation and irreversible handoff are separate durable states.
    /// Honour cancellation in that gap and terminally record that no effect
    /// ran, rather than leaving a confirmed execution stranded forever.
    private func checkCancellationBeforeHandoff(
        proposalID: UUID
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            // Database writers may themselves observe the caller's cancelled
            // task. Finalize from a fresh unstructured task so cancellation
            // cannot suppress the durable "nothing ran" transition.
            let claims = self.claims
            let cancelledAt = now()
            _ = try? await Task {
                try await claims.cancelSkillExecution(
                    proposalID: proposalID,
                    at: cancelledAt)
            }.value
            throw error
        }
    }
}

/// An error that names its own category, so settlement records a typed
/// category instead of guessing one from a message.
public protocol CategorizedFailure: Error {
    var category: FailureCategory { get }
}
