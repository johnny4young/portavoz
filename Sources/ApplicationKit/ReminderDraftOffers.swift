import Foundation
import PortavozCore
import StorageKit

/// One exact, confirmed commitment Portavoz may offer to copy into Reminders.
/// The snapshot is load-bearing: confirmation must still match all of it.
public struct ReminderDraftOffer: Equatable, Sendable, Identifiable {
    public let commitment: Commitment
    public let draft: ReminderDraft
    public let offerKey: String
    public let isRetry: Bool

    public var id: String { offerKey }

    public init?(commitment: Commitment, isRetry: Bool = false) {
        guard commitment.status == .confirmed,
              commitment.deletedAt == nil
        else { return nil }
        let arguments = Self.arguments(for: commitment)
        guard let draft = try? ReminderDraftSkill.draft(from: arguments),
              draft.commitmentID == commitment.id
        else { return nil }
        self.commitment = commitment
        self.draft = draft
        offerKey = ReminderDraftSkill.idempotencyKey(for: commitment.id)
        self.isRetry = isRetry
    }

    public func registration(at timestamp: Date) -> SkillOfferRegistration {
        SkillOfferRegistration(
            offerKey: offerKey,
            definition: ReminderDraftSkill.definition,
            requestedInputDataClasses:
                ReminderDraftSkill.definition.inputDataClasses,
            subject: .commitment(commitment.id),
            reason: .confirmedCommitment,
            proposedAt: timestamp)
    }

    static func arguments(for commitment: Commitment) -> [SkillArgument] {
        var arguments: [SkillArgument] = [.text(commitment.title)]
        if let dueAt = commitment.dueAt {
            arguments.append(.date(dueAt))
        }
        arguments.append(.commitment(commitment.id))
        return arguments
    }

    static func arguments(for draft: ReminderDraft) -> [SkillArgument] {
        var arguments: [SkillArgument] = [.text(draft.title)]
        if let dueAt = draft.dueAt {
            arguments.append(.date(dueAt))
        }
        if let commitmentID = draft.commitmentID {
            arguments.append(.commitment(commitmentID))
        }
        return arguments
    }
}

/// The subject-local projection of a durable Skill receipt. It deliberately
/// contains no commitment title or Reminders-list identity.
public struct ReminderDraftReceipt: Equatable, Sendable {
    public let commitmentID: CommitmentID
    public let proposalID: UUID
    public let state: SkillExecutionState
    public let attempt: Int
    public let updatedAt: Date

    public init(
        commitmentID: CommitmentID,
        proposalID: UUID,
        state: SkillExecutionState,
        attempt: Int,
        updatedAt: Date
    ) {
        self.commitmentID = commitmentID
        self.proposalID = proposalID
        self.state = state
        self.attempt = attempt
        self.updatedAt = updatedAt
    }

    init(commitmentID: CommitmentID, execution: SkillExecutionRecord) {
        self.commitmentID = commitmentID
        proposalID = execution.proposalID
        state = execution.state
        attempt = execution.attempt
        updatedAt = execution.updatedAt
    }
}

public struct ReminderDraftSurfaceItem: Equatable, Sendable, Identifiable {
    public let commitmentID: CommitmentID
    public let offer: ReminderDraftOffer?
    public let receipt: ReminderDraftReceipt?

    public var id: CommitmentID { commitmentID }

    public init(
        commitmentID: CommitmentID,
        offer: ReminderDraftOffer?,
        receipt: ReminderDraftReceipt?
    ) {
        self.commitmentID = commitmentID
        self.offer = offer
        self.receipt = receipt
    }
}

public struct ReminderDraftSurface: Equatable, Sendable {
    public let items: [ReminderDraftSurfaceItem]

    public init(items: [ReminderDraftSurfaceItem]) {
        self.items = items
    }
}

public enum ReminderDraftSurfaceRequestError: Error, Equatable, Sendable {
    case invalidCommitments
}

/// A Radar page is bounded to 200 items. Keep the Skill projection on the same
/// ceiling so one presentation can never turn into an unbounded `IN` query.
public struct ReminderDraftSurfaceRequest: Equatable, Sendable {
    public static let maximumCommitmentCount = 200
    public let commitments: [Commitment]

    public init(commitments: [Commitment]) throws {
        let identities = Set(commitments.map(\.id))
        guard commitments.count <= Self.maximumCommitmentCount,
              identities.count == commitments.count
        else { throw ReminderDraftSurfaceRequestError.invalidCommitments }
        self.commitments = commitments
    }
}

public protocol ReminderDraftSurfaceStore:
    SkillExecutionPolicyReading,
    SkillOfferAuthorityWriting,
    Sendable {
    func dismissedSkillOffers(offerKeys: [String]) async throws -> Set<String>
    func skillExecutions(
        idempotencyKeys: [String]
    ) async throws -> [SkillExecutionRecord]
    func dismissSkillOffer(
        offerKey: String,
        skillID: String,
        at timestamp: Date
    ) async throws
}

extension MeetingStore: ReminderDraftSurfaceStore {}

/// Loads one page through three bounded reads, never one execution query per
/// commitment. Receipts remain visible while policy is paused or disabled;
/// only the actionable proposal disappears.
public struct LoadReminderDraftSurface: ApplicationUseCase {
    private let store: any ReminderDraftSurfaceStore
    private let now: @Sendable () -> Date

    public init(
        store: any ReminderDraftSurfaceStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(
        _ request: ReminderDraftSurfaceRequest
    ) async throws -> ReminderDraftSurface {
        let candidateKeys = request.commitments.map {
            ReminderDraftSkill.idempotencyKey(for: $0.id)
        }
        let candidates = request.commitments.compactMap {
            ReminderDraftOffer(commitment: $0)
        }
        guard !candidates.isEmpty else {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: candidateKeys,
                active: [])
            return ReminderDraftSurface(items: [])
        }
        let keys = candidates.map(\.offerKey)
        async let policyRead = store.skillExecutionPolicy()
        async let dismissalRead = store.dismissedSkillOffers(offerKeys: keys)
        async let executionRead = store.skillExecutions(idempotencyKeys: keys)
        let (policy, dismissed, executions) = try await (
            policyRead,
            dismissalRead,
            executionRead)
        let records = try Self.executionRecords(
            executions,
            allowedKeys: Set(keys))

        let items = candidates.map { candidate in
            let execution = records[candidate.offerKey]
            let receipt = execution.map {
                ReminderDraftReceipt(
                    commitmentID: candidate.commitment.id,
                    execution: $0)
            }
            let mayOffer = policy.isEnabled(skillID: ReminderDraftSkill.id)
                && !dismissed.contains(candidate.offerKey)
                && (execution == nil || execution?.state == .failed)
            return ReminderDraftSurfaceItem(
                commitmentID: candidate.commitment.id,
                offer: mayOffer
                    ? ReminderDraftOffer(
                        commitment: candidate.commitment,
                        isRetry: execution?.state == .failed)
                    : nil,
                receipt: receipt)
        }
        let timestamp = now()
        try await store.reconcileSkillOffers(
            candidateOfferKeys: candidateKeys,
            active: items.compactMap(\.offer).map {
                $0.registration(at: timestamp)
            })
        return ReminderDraftSurface(items: items)
    }

    private static func executionRecords(
        _ executions: [SkillExecutionRecord],
        allowedKeys: Set<String>
    ) throws -> [String: SkillExecutionRecord] {
        var records: [String: SkillExecutionRecord] = [:]
        for execution in executions {
            guard allowedKeys.contains(execution.idempotencyKey),
                  execution.skillID == ReminderDraftSkill.id,
                  execution.skillVersion == ReminderDraftSkill.version,
                  records[execution.idempotencyKey] == nil
            else { throw ReminderDraftSurfaceRequestError.invalidCommitments }
            records[execution.idempotencyKey] = execution
        }
        return records
    }
}

public struct DismissReminderDraftOffer: ApplicationUseCase {
    private let store: any ReminderDraftSurfaceStore
    private let now: @Sendable () -> Date

    public init(
        store: any ReminderDraftSurfaceStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func execute(_ offer: ReminderDraftOffer) async throws {
        guard let exact = ReminderDraftOffer(commitment: offer.commitment),
              exact.offerKey == offer.offerKey,
              exact.draft == offer.draft
        else { return }
        try await store.dismissSkillOffer(
            offerKey: offer.offerKey,
            skillID: ReminderDraftSkill.id,
            at: now())
    }
}

public enum ReminderDraftProposalFactory {
    public static func durableProposalID(
        requested: UUID,
        existing: SkillExecutionRecord?,
        idempotencyKey: String
    ) -> UUID? {
        guard let existing else { return requested }
        guard existing.skillID == ReminderDraftSkill.id,
              existing.skillVersion == ReminderDraftSkill.version,
              existing.idempotencyKey == idempotencyKey
        else { return nil }
        guard existing.proposalID == requested || existing.state == .failed else {
            return nil
        }
        return existing.proposalID
    }

    public static func proposal(
        proposalID: UUID = UUID(),
        offer: ReminderDraftOffer,
        at now: Date
    ) -> (proposal: SkillProposal, idempotencyKey: String)? {
        guard let exact = ReminderDraftOffer(commitment: offer.commitment),
              exact.offerKey == offer.offerKey,
              exact.draft == offer.draft
        else { return nil }
        return (
            SkillProposal(
                id: proposalID,
                definition: ReminderDraftSkill.definition,
                subject: .commitment(offer.commitment.id),
                requestedCapabilities: [
                    .readMeetingMaterial,
                    .writeLocalDraft
                ],
                requestedInputDataClasses:
                    ReminderDraftSkill.definition.inputDataClasses,
                arguments: ReminderDraftOffer.arguments(for: offer.draft),
                proposedAt: now),
            offer.offerKey)
    }
}
