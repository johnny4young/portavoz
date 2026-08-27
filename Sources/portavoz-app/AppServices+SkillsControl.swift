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
        if usesTemporaryMeetingStore,
           receiptScope != .recent,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-refresh-handshake") {
            try await UITestFeatureHandshake.pauseIfRequested(
                argument: "-simulate-skill-receipt-refresh-handshake",
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_SKILL_RECEIPT_REFRESH_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_SKILL_RECEIPT_REFRESH_CONTINUE_PATH")
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
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-control-mutation-unavailable") {
            throw SimulatedSkillControlMutationFailure()
        }
        return outcome
    }

    func loadSkillOfferReview() async throws -> SkillOfferReviewSnapshot {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-proposal-refresh-handshake") {
            try await UITestFeatureHandshake.pauseIfRequested(
                argument: "-simulate-skill-proposal-refresh-handshake",
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_SKILL_PROPOSAL_REFRESH_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_SKILL_PROPOSAL_REFRESH_CONTINUE_PATH")
        }
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

    func resolveSkillReceiptContextDestination(
        proposalID: UUID
    ) async throws -> SkillReceiptContextNavigationOutcome {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-skill-receipt-context-unavailable") {
            throw SimulatedSkillReceiptContextFailure()
        }
        return try await ResolveSkillReceiptContextDestination(store: store)
            .execute(proposalID)
    }
}

private struct SimulatedSkillControlFailure: Error {}
private struct SimulatedSkillControlMutationFailure: Error {}
private struct SimulatedSkillProposalFailure: Error {}
private struct SimulatedSkillProposalDismissalFailure: Error {}
private struct SimulatedSkillProposalReviewFailure: Error {}
private struct SimulatedSkillReceiptRevocationFailure: Error {}
private struct SimulatedSkillReceiptRecoveryFailure: Error {}
private struct SimulatedSkillReceiptContextFailure: Error {}

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
