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

    func loadSkillReceiptInspection(
        proposalID: UUID
    ) async throws -> SkillControlCenterReceiptInspection {
        try await LoadSkillReceiptInspection(store: store).execute(proposalID)
    }
}

private struct SimulatedSkillControlFailure: Error {}
private struct SimulatedSkillReceiptScopeFailure: Error {}
