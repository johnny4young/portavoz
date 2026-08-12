import ApplicationKit
import PortavozCore
import SwiftUI

/// AUTO-6a — a read-only projection of the content-free, append-only execution
/// log. It does not expose proposal arguments, destinations, or meeting text.
struct SkillReceiptInspectionSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let receipt: SkillControlCenterReceipt

    @State private var inspection: SkillControlCenterReceiptInspection?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            Label(
                "This history contains only execution state, attempt, and time — never meeting content.",
                systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("skill-receipt-inspection-privacy")
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 380)
        .task(id: receipt.proposalID) {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Receipt details")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("skill-receipt-inspection")
                Text(SkillReceiptPresentation.skillTitle(currentSkillID))
                    .font(.headline)
                Text(currentStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close receipt details")
            .accessibilityIdentifier("skill-receipt-inspection-close")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, inspection == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading receipt history…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("skill-receipt-inspection-loading")
        } else if loadFailed || inspection == nil {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Receipt history is unavailable",
                    systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("skill-receipt-inspection-error")
                Text(
                    "Portavoz could not verify this receipt. This inspector never runs or retries a Skill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await load() }
                }
                .accessibilityIdentifier("skill-receipt-inspection-retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let inspection {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(inspection.events) { event in
                        eventRow(event)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("skill-receipt-inspection-timeline")
        }
    }

    private func eventRow(
        _ event: SkillControlCenterReceiptEvent
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: eventSymbol(event.kind))
                .foregroundStyle(eventTint(event.kind))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(eventTitle(event.kind))
                    .font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text(L10n.format("Attempt %d", event.attempt))
                    if let category = event.failureCategory {
                        Text("·")
                        Text(failureCategoryTitle(category))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    event.occurredAt,
                    format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "skill-receipt-inspection-event-\(event.sequence)")
    }

    private var currentSkillID: String {
        inspection?.skillID ?? receipt.skillID
    }

    private var currentStatus: String {
        SkillReceiptPresentation.status(
            skillID: currentSkillID,
            state: inspection?.state ?? receipt.state)
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            inspection = try await services.loadSkillReceiptInspection(
                proposalID: receipt.proposalID)
            loadFailed = false
        } catch {
            inspection = nil
            loadFailed = true
        }
    }

    private func eventTitle(
        _ kind: SkillControlCenterReceiptEventKind
    ) -> String {
        switch kind {
        case .confirmed: L10n.text("Confirmation recorded")
        case .started: L10n.text("Attempt started")
        case .succeeded: L10n.text("Attempt reported success")
        case .failed: L10n.text("Attempt reported failure")
        case .cancelled: L10n.text("Cancelled before handoff")
        }
    }

    private func eventSymbol(
        _ kind: SkillControlCenterReceiptEventKind
    ) -> String {
        switch kind {
        case .confirmed: "person.crop.circle.badge.checkmark"
        case .started: "play.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func eventTint(
        _ kind: SkillControlCenterReceiptEventKind
    ) -> Color {
        switch kind {
        case .confirmed, .started: .secondary
        case .succeeded: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func failureCategoryTitle(_ category: FailureCategory) -> String {
        switch category {
        case .critical: L10n.text("Critical failure")
        case .recoverable: L10n.text("Recoverable failure")
        case .degradable: L10n.text("Degraded result")
        case .external: L10n.text("External-system failure")
        case .destructive: L10n.text("Destructive-risk failure")
        }
    }
}
