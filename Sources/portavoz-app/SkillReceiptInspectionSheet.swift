import ApplicationKit
import PortavozCore
import SwiftUI

/// AUTO-6 — a content-free projection of the append-only execution log. It can
/// revoke a confirmation only before handoff; it never receives the material
/// required to execute or retry a Skill.
struct SkillReceiptInspectionSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let receipt: SkillControlCenterReceipt
    let receiptDidChange: () -> Void
    let openRecoveryDestination: (SkillOfferReviewDestination) -> Void

    @State private var inspection: SkillControlCenterReceiptInspection?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var isRevoking = false
    @State private var revocationFailed = false
    @State private var isResolvingRecovery = false
    @State private var recoveryFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            if inspection?.state == .confirmed {
                Divider()
                revocationContent
            }
            if inspection?.state == .failed {
                Divider()
                recoveryContent
            }
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
        .interactiveDismissDisabled(isRevoking || isResolvingRecovery)
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
            .disabled(isRevoking || isResolvingRecovery)
        }
    }

    @ViewBuilder
    private var recoveryContent: some View {
        switch inspection?.recoveryAvailability ?? .unavailable {
        case .reviewInContext:
            if isResolvingRecovery {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying recovery context…")
                }
                .accessibilityIdentifier("skill-receipt-recovery-progress")
            } else if recoveryFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Recovery context could not be verified. Nothing ran.",
                        systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("skill-receipt-recovery-error")
                    Button("Try again") {
                        Task { await resolveRecovery() }
                    }
                    .accessibilityIdentifier("skill-receipt-recovery-retry")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Return to the original context and review a fresh proposal. This does not run the Skill.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Review recovery in context") {
                        Task { await resolveRecovery() }
                    }
                    .accessibilityHint(
                        "Returns to the original subject without running the Skill")
                    .accessibilityIdentifier("skill-receipt-recovery-action")
                }
            }
        case .residentMenuBar:
            Label(
                "Review this recovery from the menu bar beside the calendar event. Nothing runs automatically.",
                systemImage: "menubar.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("skill-receipt-recovery-resident")
        case .verifyExternally:
            Label(
                "The outcome may exist outside Portavoz. Verify the external destination before continuing.",
                systemImage: "arrow.up.right.square")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("skill-receipt-recovery-external")
        case .unavailable:
            Label(
                "A safe recovery route is unavailable. This receipt remains available for review.",
                systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("skill-receipt-recovery-unavailable")
        }
    }

    @ViewBuilder
    private var revocationContent: some View {
        if isRevoking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Revoking approval…")
            }
            .accessibilityIdentifier("skill-receipt-revoke-progress")
        } else if revocationFailed {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Approval could not be revoked. The run is still waiting.",
                    systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("skill-receipt-revoke-error")
                Button("Try again") {
                    Task { await revokeApproval() }
                }
                .accessibilityIdentifier("skill-receipt-revoke-retry")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "This approval can be revoked only while execution has not started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Revoke approval", role: .destructive) {
                    Task { await revokeApproval() }
                }
                .accessibilityHint(
                    "Cancels this run only if execution has not started")
                .accessibilityIdentifier("skill-receipt-revoke-action")
            }
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
                    "Portavoz could not verify this receipt. This inspector never executes or retries a Skill effect.")
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
            state: inspection?.state ?? receipt.state,
            failureCategory:
                inspection?.failureCategory ?? receipt.failureCategory)
    }

    @MainActor
    private func load() async {
        guard !isLoading, !isRevoking, !isResolvingRecovery else { return }
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

    @MainActor
    private func revokeApproval() async {
        guard inspection?.state == .confirmed,
              !isRevoking,
              !isResolvingRecovery
        else { return }
        isRevoking = true
        revocationFailed = false
        defer { isRevoking = false }
        do {
            _ = try await services.revokeWaitingSkillExecution(
                proposalID: receipt.proposalID)
            guard !Task.isCancelled else { return }
            await reloadAfterVerifiedMutation()
            receiptDidChange()
        } catch is CancellationError {
            return
        } catch {
            revocationFailed = true
        }
    }

    /// A verified mutation must bypass `load()`'s user-load exclusion: the
    /// revocation owns `isRevoking` until its fresh receipt has been projected.
    /// Keeping the two paths separate prevents a successful cancellation from
    /// leaving the sheet on its stale `confirmed` history.
    @MainActor
    private func reloadAfterVerifiedMutation() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let refreshed = try await services.loadSkillReceiptInspection(
                proposalID: receipt.proposalID)
            guard !Task.isCancelled else { return }
            inspection = refreshed
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            inspection = nil
            loadFailed = true
        }
    }

    @MainActor
    private func resolveRecovery() async {
        guard inspection?.state == .failed,
              inspection?.recoveryAvailability == .reviewInContext,
              !isLoading,
              !isRevoking,
              !isResolvingRecovery
        else { return }
        isResolvingRecovery = true
        recoveryFailed = false
        defer { isResolvingRecovery = false }
        do {
            let outcome = try await services
                .resolveSkillReceiptRecoveryDestination(
                    proposalID: receipt.proposalID)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .unavailable:
                recoveryFailed = true
            case .destination(let destination):
                isResolvingRecovery = false
                openRecoveryDestination(destination)
                dismiss()
            }
        } catch is CancellationError {
            return
        } catch {
            recoveryFailed = true
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
