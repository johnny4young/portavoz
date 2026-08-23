import ApplicationKit
import PortavozCore

enum SkillReceiptPresentation {
    static func skillTitle(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id: L10n.text("Recap draft")
        case EmailRecapDraftSkill.id: L10n.text("Email recap draft")
        case SecretGistPublishSkill.id: L10n.text("Secret Gist publication")
        case MeetingPackageExportSkill.id: L10n.text("Text-only meeting package")
        case ReminderDraftSkill.id: L10n.text("Reminder draft")
        case PreMeetingBriefSkill.id: L10n.text("Pre-meeting brief")
        default: L10n.text("Unknown action")
        }
    }

    static func status(
        skillID: String,
        state: SkillExecutionState,
        failureCategory: FailureCategory?
    ) -> String {
        if let externalStatus = externalStatus(
            skillID: skillID,
            state: state,
            failureCategory: failureCategory
        ) {
            return externalStatus
        }
        return switch state {
        case .proposed: L10n.text("Proposed — nothing ran")
        case .previewed: L10n.text("Previewed — nothing ran")
        case .confirmed: L10n.text("Confirmed — waiting")
        case .executing: L10n.text("Needs review after interruption")
        case .succeeded: L10n.text("Succeeded")
        case .failed:
            if failureCategory == .external || failureCategory == .destructive {
                L10n.text("Outcome unverified — check the external destination")
            } else if failureCategory == nil {
                L10n.text("Failed — recovery is unavailable")
            } else {
                L10n.text("Failed — review is available")
            }
        case .dismissed: L10n.text("Cancelled — nothing ran")
        }
    }

    private static func externalStatus(
        skillID: String,
        state: SkillExecutionState,
        failureCategory: FailureCategory?
    ) -> String? {
        switch (skillID, state) {
        case (EmailRecapDraftSkill.id, .succeeded):
            L10n.text("Handoff requested")
        case (EmailRecapDraftSkill.id, .failed):
            L10n.text("Email app did not open")
        case (EmailRecapDraftSkill.id, .executing):
            L10n.text("Handoff status unknown")
        case (SecretGistPublishSkill.id, .succeeded):
            L10n.text("Secret Gist published")
        case (SecretGistPublishSkill.id, .failed)
            where failureCategory == .external
                || failureCategory == .destructive:
            L10n.text("Publication outcome unknown — check GitHub")
        case (SecretGistPublishSkill.id, .executing):
            L10n.text("Publication outcome unknown — check GitHub")
        default:
            nil
        }
    }
}
