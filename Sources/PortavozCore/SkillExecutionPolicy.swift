import Foundation

/// The device-local switchboard consulted immediately before a skill may run.
///
/// Missing per-skill rows mean enabled so a newly shipped local skill can be
/// proposed without a migration per catalogue entry. The global pause remains
/// an independent override: pausing never destroys the user's individual
/// choices, and resuming restores them exactly.
public struct SkillExecutionPolicy: Equatable, Sendable {
    public let isPaused: Bool
    public let disabledSkillIDs: Set<String>

    public init(
        isPaused: Bool = false,
        disabledSkillIDs: Set<String> = []
    ) {
        self.isPaused = isPaused
        self.disabledSkillIDs = disabledSkillIDs
    }

    public func isEnabled(skillID: String) -> Bool {
        !isPaused && !disabledSkillIDs.contains(skillID)
    }

    public func isIndividuallyEnabled(skillID: String) -> Bool {
        !disabledSkillIDs.contains(skillID)
    }
}
