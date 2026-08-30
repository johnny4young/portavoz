import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

enum AppStandingSkillControlError: Error {
    case unavailable
}

extension AppServices {
    func loadStandingSkillAutomationCenter(
        historyLimit: Int =
            StandingSkillAutomationCenterSnapshot.defaultHistoryLimit
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        if usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-standing-skill-control-unavailable") {
            throw AppStandingSkillControlError.unavailable
        }
        return try await LoadStandingSkillAutomationCenter(store: store)
            .execute(StandingSkillAutomationCenterRequest(
                historyLimit: historyLimit))
    }

    func createStandingPreMeetingBriefRule(
        maximumDailyExecutions: Int,
        historyLimit: Int
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        _ = try await CreateStandingSkillRule(store: store).execute(
            CreateStandingSkillRuleRequest(
                template: .prepareEveryUpcomingBrief,
                maximumDailyExecutions: maximumDailyExecutions))
        try await standingPreMeetingBriefs.reconcileNow()
        return try await loadStandingSkillAutomationCenter(
            historyLimit: historyLimit)
    }

    func setStandingPreMeetingBriefRule(
        _ id: StandingSkillRuleID,
        isEnabled: Bool,
        historyLimit: Int
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        let outcome = try await ManageStandingSkillRule(store: store).execute(
            .setEnabled(id: id, isEnabled: isEnabled))
        guard outcome == .updated else {
            throw AppStandingSkillControlError.unavailable
        }
        try await standingPreMeetingBriefs.reconcileNow()
        return try await loadStandingSkillAutomationCenter(
            historyLimit: historyLimit)
    }

    func deleteStandingPreMeetingBriefRule(
        _ id: StandingSkillRuleID,
        historyLimit: Int
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        let outcome = try await ManageStandingSkillRule(store: store).execute(
            .delete(id: id))
        guard outcome == .deleted else {
            throw AppStandingSkillControlError.unavailable
        }
        try await standingPreMeetingBriefs.reconcileNow()
        return try await loadStandingSkillAutomationCenter(
            historyLimit: historyLimit)
    }

    func retryStandingPreMeetingBrief(
        proposalID: UUID,
        historyLimit: Int
    ) async throws -> StandingSkillAutomationCenterSnapshot {
        let current = try await loadStandingSkillAutomationCenter(
            historyLimit: StandingSkillAutomationCenterSnapshot
                .maximumHistoryLimit)
        guard current.history.contains(where: {
            $0.record.proposalID == proposalID
                && $0.record.state == .failed
                && $0.record.attempt
                    < StandingSkillExecutionPolicy.maximumAutomaticAttempts
        }) else { throw AppStandingSkillControlError.unavailable }
        try await standingPreMeetingBriefs.retryNow(proposalID)
        return try await loadStandingSkillAutomationCenter(
            historyLimit: historyLimit)
    }

    func loadStandingPreMeetingBrief(
        proposalID: UUID
    ) async throws -> MeetingBrief {
        try await LoadStandingSkillBrief(store: store).execute(proposalID)
    }
}
