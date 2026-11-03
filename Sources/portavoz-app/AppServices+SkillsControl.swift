import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func loadSkillControlCenter(
        receiptScope: SkillExecutionReviewScope = .recent,
        receiptSkillID: String? = nil,
        receiptPeriod: SkillExecutionReviewPeriod = .anytime,
        receiptLimit: Int = SkillControlCenterSnapshot.defaultReceiptLimit
    ) async throws -> SkillControlCenterSnapshot {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
            "-simulate-skill-control-unavailable"
        ) {
            throw SimulatedSkillControlFailure()
        }
        let snapshot = try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(
                receiptScope: receiptScope,
                receiptSkillID: receiptSkillID,
                receiptPeriod: receiptPeriod,
                receiptLimit: receiptLimit))
        guard usesTemporaryMeetingStore,
              receiptScope != .recent,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-scope-unavailable")
        else {
            return snapshot
        }
        return SkillControlCenterSnapshot(
            isPaused: snapshot.isPaused,
            skills: snapshot.skills,
            receiptScope: snapshot.receiptScope,
            receipts: [],
            receiptSkillID: snapshot.receiptSkillID,
            receiptPeriod: snapshot.receiptPeriod,
            receiptLoadState: .unavailable)
    }

    func manageSkillControl(
        _ action: ManageSkillControlAction
    ) async throws -> ManageSkillControlOutcome {
        let outcome = try await ManageSkillControl(store: store).execute(action)
        if outcome == .updated {
            await standingPreMeetingBriefs.kick()
        }
        return outcome
    }

    func loadSkillOfferReview() async throws -> SkillOfferReviewSnapshot {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-proposal-unavailable") {
            throw SimulatedSkillProposalFailure()
        }
        return try await LoadSkillOfferReview(store: store).execute(
            LoadSkillOfferReviewRequest())
    }

    func dismissSkillOfferReview(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewDismissalOutcome {
        return try await DismissSkillOfferReview(store: store).execute(reviewID)
    }

    func resolveSkillOfferReviewDestination(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewNavigationOutcome {
        return try await ResolveSkillOfferReviewDestination(store: store)
            .execute(reviewID)
    }

    func loadSkillReceiptInspection(
        proposalID: UUID
    ) async throws -> SkillControlCenterReceiptInspection {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-policy-unavailable") {
            return try await LoadSkillReceiptInspection(
                store: UnavailableReceiptPolicyStore(store: store)
            ).execute(proposalID)
        }
        return try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
    }

    func revokeWaitingSkillExecution(
        proposalID: UUID
    ) async throws -> WaitingSkillExecutionRevocationOutcome {
        return try await RevokeWaitingSkillExecution(store: store)
            .execute(proposalID)
    }

    func resolveSkillReceiptRecoveryDestination(
        proposalID: UUID
    ) async throws -> SkillReceiptRecoveryNavigationOutcome {
        return try await ResolveSkillReceiptRecoveryDestination(store: store)
            .execute(proposalID)
    }

    func resolveSkillReceiptContextDestination(
        proposalID: UUID
    ) async throws -> SkillReceiptContextNavigationOutcome {
        return try await ResolveSkillReceiptContextDestination(store: store)
            .execute(proposalID)
    }
}

private struct SimulatedSkillControlFailure: Error {}
private struct SimulatedSkillProposalFailure: Error {}

/// Proves that policy-independent receipt paths do not consult an unrelated
/// authority. The disposable-store gate keeps this failure out of production.
private struct UnavailableReceiptPolicyStore: SkillReceiptInspectionStore {
    let store: MeetingStore

    func skillExecutionAudit(
        proposalID: UUID
    ) async throws -> SkillExecutionAudit? {
        try await store.skillExecutionAudit(proposalID: proposalID)
    }

    func skillExecutionPolicy() async throws -> SkillExecutionPolicy {
        throw SimulatedSkillReceiptPolicyFailure()
    }
}

private struct SimulatedSkillReceiptPolicyFailure: Error {}
