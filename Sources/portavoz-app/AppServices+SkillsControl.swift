import ApplicationKit
import Foundation

extension AppServices {
    func loadSkillControlCenter() async throws -> SkillControlCenterSnapshot {
        if ProcessInfo.processInfo.arguments.contains(
            "-simulate-skill-control-unavailable"
        ) {
            throw SimulatedSkillControlFailure()
        }
        return try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest())
    }

    func manageSkillControl(
        _ action: ManageSkillControlAction
    ) async throws -> ManageSkillControlOutcome {
        try await ManageSkillControl(store: store).execute(action)
    }
}

private struct SimulatedSkillControlFailure: Error {}
