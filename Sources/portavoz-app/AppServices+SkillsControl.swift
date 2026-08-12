import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    func loadSkillControlCenter(
        receiptScope: SkillExecutionReviewScope = .recent
    ) async throws -> SkillControlCenterSnapshot {
        if ProcessInfo.processInfo.arguments.contains(
            "-simulate-skill-control-unavailable"
        ) {
            throw SimulatedSkillControlFailure()
        }
        if receiptScope != .recent,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-scope-unavailable") {
            throw SimulatedSkillReceiptScopeFailure()
        }
        return try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(receiptScope: receiptScope))
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
}

private struct SimulatedSkillControlFailure: Error {}
private struct SimulatedSkillReceiptScopeFailure: Error {}
private struct SimulatedSkillProposalFailure: Error {}
private struct SimulatedSkillProposalDismissalFailure: Error {}
private struct SimulatedSkillReceiptRevocationFailure: Error {}
