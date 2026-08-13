import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    func loadSkillControlCenter(
        receiptScope: SkillExecutionReviewScope = .recent
    ) async throws -> SkillControlCenterSnapshot {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
            "-simulate-skill-control-unavailable"
        ) {
            throw SimulatedSkillControlFailure()
        }
        if usesTemporaryMeetingStore,
           receiptScope != .recent,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-refresh-delay") {
            try await Task.sleep(for: .seconds(4))
        }
        let snapshot = try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(receiptScope: receiptScope))
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
            receiptLoadState: .unavailable)
    }

    func manageSkillControl(
        _ action: ManageSkillControlAction
    ) async throws -> ManageSkillControlOutcome {
        try await ManageSkillControl(store: store).execute(action)
    }

    func loadSkillOfferReview() async throws -> SkillOfferReviewSnapshot {
        if ProcessInfo.processInfo.arguments.contains(
            "-simulate-skill-proposal-unavailable"
        ) {
            throw SimulatedSkillProposalFailure()
        }
        return try await LoadSkillOfferReview(store: store).execute(
            LoadSkillOfferReviewRequest())
    }

    func dismissSkillOfferReview(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewDismissalOutcome {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-proposal-dismiss-unavailable") {
            throw SimulatedSkillProposalDismissalFailure()
        }
        return try await DismissSkillOfferReview(store: store).execute(reviewID)
    }

    func resolveSkillOfferReviewDestination(
        _ reviewID: UUID
    ) async throws -> SkillOfferReviewNavigationOutcome {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-proposal-review-unavailable") {
            throw SimulatedSkillProposalReviewFailure()
        }
        return try await ResolveSkillOfferReviewDestination(store: store)
            .execute(reviewID)
    }

    func loadSkillReceiptInspection(
        proposalID: UUID
    ) async throws -> SkillControlCenterReceiptInspection {
        try await LoadSkillReceiptInspection(store: store).execute(proposalID)
    }

    func revokeWaitingSkillExecution(
        proposalID: UUID
    ) async throws -> WaitingSkillExecutionRevocationOutcome {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-revoke-unavailable") {
            throw SimulatedSkillReceiptRevocationFailure()
        }
        return try await RevokeWaitingSkillExecution(store: store)
            .execute(proposalID)
    }

    func resolveSkillReceiptRecoveryDestination(
        proposalID: UUID
    ) async throws -> SkillReceiptRecoveryNavigationOutcome {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-recovery-unavailable") {
            throw SimulatedSkillReceiptRecoveryFailure()
        }
        return try await ResolveSkillReceiptRecoveryDestination(store: store)
            .execute(proposalID)
    }
}

private struct SimulatedSkillControlFailure: Error {}
private struct SimulatedSkillProposalFailure: Error {}
private struct SimulatedSkillProposalDismissalFailure: Error {}
private struct SimulatedSkillProposalReviewFailure: Error {}
private struct SimulatedSkillReceiptRevocationFailure: Error {}
private struct SimulatedSkillReceiptRecoveryFailure: Error {}
