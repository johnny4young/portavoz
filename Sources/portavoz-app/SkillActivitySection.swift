import ApplicationKit
import PortavozCore
import SwiftUI

/// D336 — one status-scoped, content-free execution review surface.
///
/// The returned snapshot must match the selected scope before this view shows
/// any row. Loading and failures therefore cannot relabel stale evidence.
struct SkillActivitySection: View {
    @Binding var receiptScope: SkillExecutionReviewScope
    @FocusState private var focusedReceiptID: UUID?
    @AccessibilityFocusState private var accessibilityFocusedReceiptID: UUID?

    let snapshot: SkillControlCenterSnapshot?
    let isLoading: Bool
    let isMutating: Bool
    let loadFailed: Bool
    let focusRequestID: UUID?
    let retry: () -> Void
    let inspectReceipt: (SkillControlCenterReceipt) -> Void

    var body: some View {
        Group {
            scopePicker

            if snapshot?.receiptScope != receiptScope {
                unavailableContent
            } else if let receipts = snapshot?.receipts, receipts.isEmpty {
                emptyContent
            } else {
                ForEach(snapshot?.receipts ?? []) { receipt in
                    receiptRow(receipt)
                }
                Text("Each view shows up to 20 matching runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: focusRequestID, initial: true) {
            guard let focusRequestID else { return }
            Task { @MainActor in
                await Task.yield()
                guard self.focusRequestID == focusRequestID else { return }
                accessibilityFocusedReceiptID = focusRequestID
                focusedReceiptID = focusRequestID
            }
        }
    }

    private var scopePicker: some View {
        Picker("Activity view", selection: $receiptScope) {
            Text("Recent")
                .tag(SkillExecutionReviewScope.recent)
                .accessibilityIdentifier(
                    "settings-skills-receipt-scope-recent")
            Text("Waiting")
                .tag(SkillExecutionReviewScope.waiting)
                .accessibilityIdentifier(
                    "settings-skills-receipt-scope-waiting")
            Text("Attention")
                .tag(SkillExecutionReviewScope.needsAttention)
                .accessibilityIdentifier(
                    "settings-skills-receipt-scope-needs-attention")
            Text("Completed")
                .tag(SkillExecutionReviewScope.completed)
                .accessibilityIdentifier(
                    "settings-skills-receipt-scope-completed")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings-skills-receipt-scope")
        .disabled(isLoading || isMutating)
    }

    @ViewBuilder
    private var unavailableContent: some View {
        if loadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Receipt history is unavailable",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "settings-skills-receipt-scope-error")
                Text("The selected activity view could not be verified. No runs are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try again", action: retry)
                    .accessibilityIdentifier(
                        "settings-skills-receipt-scope-retry")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading receipt history…")
            }
            .accessibilityIdentifier("settings-skills-receipt-scope-loading")
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(emptyTitle, systemImage: "checkmark.seal")
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "settings-skills-empty-receipts-\(receiptScope.rawValue)")
    }

    private var emptyTitle: LocalizedStringKey {
        switch receiptScope {
        case .recent: "No skill runs yet"
        case .waiting: "No Skill runs are waiting"
        case .needsAttention: "No Skill runs need attention"
        case .completed: "No completed Skill runs"
        }
    }

    private var emptyDetail: LocalizedStringKey {
        switch receiptScope {
        case .recent:
            "A receipt appears here only after you confirm a skill."
        case .waiting:
            "Confirmed runs appear here until execution begins."
        case .needsAttention:
            "Interrupted and failed runs appear here for review."
        case .completed:
            "Successful and pre-handoff cancelled runs appear here."
        }
    }

    private func receiptRow(
        _ receipt: SkillControlCenterReceipt
    ) -> some View {
        Button {
            inspectReceipt(receipt)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: receiptIcon(receipt.state))
                    .foregroundStyle(receiptTint(receipt.state))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skillTitle(receipt.skillID))
                        .font(.callout.weight(.medium))
                    Text(receiptStatus(receipt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    receipt.updatedAt,
                    format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .focused($focusedReceiptID, equals: receipt.proposalID)
        .accessibilityFocused(
            $accessibilityFocusedReceiptID,
            equals: receipt.proposalID)
        .accessibilityLabel(receiptAccessibilityLabel(receipt))
        .accessibilityHint("Inspect execution history")
        .accessibilityIdentifier(
            "settings-skill-receipt-\(receipt.skillID)")
    }

    private func skillTitle(_ skillID: String) -> String {
        SkillReceiptPresentation.skillTitle(skillID)
    }

    private func receiptStatus(_ receipt: SkillControlCenterReceipt) -> String {
        SkillReceiptPresentation.status(
            skillID: receipt.skillID,
            state: receipt.state,
            failureCategory: receipt.failureCategory)
    }

    private func receiptAccessibilityLabel(
        _ receipt: SkillControlCenterReceipt
    ) -> String {
        "\(skillTitle(receipt.skillID)). \(receiptStatus(receipt))"
    }

    private func receiptIcon(_ state: SkillExecutionState) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed, .executing: "exclamationmark.triangle.fill"
        case .dismissed: "xmark.circle"
        case .proposed, .previewed, .confirmed: "clock"
        }
    }

    private func receiptTint(_ state: SkillExecutionState) -> Color {
        switch state {
        case .succeeded: .green
        case .failed, .executing: .orange
        case .dismissed, .proposed, .previewed, .confirmed: .secondary
        }
    }
}
