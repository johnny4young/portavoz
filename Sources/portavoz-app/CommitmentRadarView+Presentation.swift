import PortavozCore
import SwiftUI

extension CommitmentRadarView {
    func ownerName(_ item: CommitmentRadarItem) -> String {
        switch item.commitment.assignee {
        case .me:
            L10n.text("Me")
        case .unassigned:
            L10n.text("Unassigned")
        case .person:
            item.assigneeDisplayName ?? L10n.text("Unknown person")
        }
    }

    func dueLabel(_ date: Date?) -> String {
        guard let date else { return L10n.text("No due date") }
        return L10n.format("Due %@", shortDate(date))
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    func activityLabel(_ activity: CommitmentRadarActivity) -> String {
        switch activity {
        case .new: L10n.text("New")
        case .unchanged: L10n.text("Unchanged")
        case .completed: L10n.text("Completed")
        case .reopened: L10n.text("Reopened")
        }
    }

    func historyLabel(_ kind: CommitmentEventKind) -> String {
        switch kind {
        case .confirm: L10n.text("Confirmed")
        case .reassign: L10n.text("Reassigned")
        case .reschedule: L10n.text("Rescheduled")
        case .complete: L10n.text("Completed")
        case .reopen: L10n.text("Reopened")
        case .dismiss: L10n.text("Dismissed")
        }
    }

    func activityColor(_ activity: CommitmentRadarActivity) -> Color {
        switch activity {
        case .new: PVDesign.accent
        case .unchanged: .secondary
        case .completed: .green
        case .reopened: PVDesign.brandAmber
        }
    }
}
