import PortavozCore
import SwiftUI

extension CommitmentRadarView {
    @ViewBuilder func reminderDraftAction(
        _ item: CommitmentRadarItem
    ) -> some View {
        if let surface = reminderDrafts.state.items[item.id] {
            if let offer = surface.offer {
                Button(
                    offer.isRetry ? "Retry in Reminders" : "Create in Reminders"
                ) {
                    Task { await reminderDrafts.open(item.id) }
                }
                .accessibilityIdentifier(
                    "commitment-radar-reminder-create-\(item.id.rawValue.uuidString)")
                Button {
                    Task { await reminderDrafts.dismiss(item.id) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Don't suggest this reminder again")
                .accessibilityIdentifier(
                    "commitment-radar-reminder-dismiss-\(item.id.rawValue.uuidString)")
            } else if surface.receipt?.state == .succeeded {
                Label(
                    "Created in Reminders",
                    systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier(
                        "commitment-radar-reminder-created-\(item.id.rawValue.uuidString)")
            } else if let receipt = surface.receipt {
                Label(
                    reminderDraftReceiptLabel(receipt.state),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "commitment-radar-reminder-status-\(item.id.rawValue.uuidString)")
            }
        }
    }

    func reminderDraftReceiptLabel(_ state: SkillExecutionState) -> String {
        switch state {
        case .failed: L10n.text("Reminder failed")
        case .confirmed, .executing: L10n.text("Reminder needs review")
        case .proposed, .previewed, .dismissed:
            L10n.text("Reminder not created")
        case .succeeded: L10n.text("Created in Reminders")
        }
    }

    var reminderDraftCommitments: [Commitment] {
        guard model.state.mode == .confirmed else { return [] }
        return model.state.page?.items.map(\.commitment) ?? []
    }

    /// Updated-at fences title, due date, lifecycle, and owner changes without
    /// hashing user content into the SwiftUI task identity.
    var reminderDraftLoadIdentity: String {
        guard model.state.mode == .confirmed else { return "not-confirmed" }
        return reminderDraftCommitments.map {
            "\($0.id.rawValue.uuidString):\($0.updatedAt.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|")
    }

    var reminderDraftSheetBinding: Binding<Bool> {
        Binding(
            get: { reminderDrafts.state.confirmation != nil },
            set: { isPresented in
                if !isPresented { reminderDrafts.cancel() }
            })
    }

    var reminderDraftFailureBinding: Binding<Bool> {
        Binding(
            get: { reminderDrafts.state.surfaceFailure != nil },
            set: { isPresented in
                if !isPresented { reminderDrafts.clearSurfaceFailure() }
            })
    }
}
