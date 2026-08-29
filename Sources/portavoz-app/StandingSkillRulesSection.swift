import ApplicationKit
import Foundation
import OSLog
import PortavozCore
import StorageKit
import SwiftUI

private struct StandingSkillBriefTarget: Identifiable {
    let id: UUID
    let brief: MeetingBrief
}

/// AUTO-5c — explicit creation and review for the only unattended authority
/// currently admitted by the closed catalogue.
struct StandingSkillRulesSection: View {
    private static let logger = Logger(
        subsystem: "app.portavoz.mac",
        category: "standing-skill-control")

    @Environment(AppServices.self) private var services

    let policyRevision: Int
    @Binding var externalMutationInFlight: Bool
    let didChangeExecutionAuthority: () -> Void

    @State private var snapshot: StandingSkillAutomationCenterSnapshot?
    @State private var historyLimit =
        StandingSkillAutomationCenterSnapshot.defaultHistoryLimit
    @State private var dailyLimit =
        StandingSkillRuleTemplate.defaultMaximumDailyExecutions
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var loadFailed = false
    @State private var mutationFailed = false
    @State private var deleteConfirmationID: StandingSkillRuleID?
    @State private var loadingBriefID: UUID?
    @State private var briefLoadFailedID: UUID?
    @State private var selectedBrief: StandingSkillBriefTarget?

    var body: some View {
        Section("Automatic local actions") {
            Text(
                """
                You create these rules yourself. They run only reversible work \
                on this Mac and can be paused or deleted at any time.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-standing-explanation")

            if isLoading, snapshot == nil {
                loadingContent
            } else if loadFailed, snapshot == nil {
                unavailableContent
            } else if let snapshot {
                if snapshot.controls.rules.isEmpty {
                    creationPreview
                } else {
                    ForEach(snapshot.controls.rules) { item in
                        ruleRow(item, controls: snapshot.controls)
                    }
                }
                history(snapshot)
            }

            if mutationFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "The last rule change could not be verified. Reload before trying again.",
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "settings-standing-mutation-error")
                    Button("Reload automatic actions") {
                        Task { await load() }
                    }
                    .accessibilityIdentifier("settings-standing-mutation-reload")
                    .disabled(isBusy)
                }
            }
        }
        .task(id: policyRevision) { await load() }
        .sheet(item: $selectedBrief) { target in
            StandingSkillBriefSheet(brief: target.brief)
        }
    }
}

private extension StandingSkillRulesSection {
    private var isBusy: Bool {
        isLoading || isMutating || loadingBriefID != nil
    }

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading automatic actions…")
        }
        .accessibilityIdentifier("settings-standing-loading")
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Automatic actions are unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-standing-load-error")
            Text("No rule or run is shown until Portavoz verifies its local authority.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try again") { Task { await load() } }
                .accessibilityIdentifier("settings-standing-load-retry")
        }
    }

    private var creationPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Prepare every upcoming brief",
                systemImage: "calendar.badge.clock")
                .font(.callout.weight(.semibold))
            Text(
                """
                Within two hours of each upcoming calendar event, Portavoz \
                prepares one cited brief from your local library. Nothing is \
                sent, shared, or written to a file.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Stepper(
                L10n.format("Up to %d briefs per day", dailyLimit),
                value: $dailyLimit,
                in: 1...StandingSkillRule.maximumDailyExecutionCount)
                .accessibilityIdentifier("settings-standing-daily-limit")
            Button {
                Task {
                    await mutate {
                        try await services.createStandingPreMeetingBriefRule(
                            maximumDailyExecutions: dailyLimit,
                            historyLimit: historyLimit)
                    }
                }
            } label: {
                Label("Create automatic action", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings-standing-create")
            .disabled(isBusy || externalMutationInFlight)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-standing-preview")
    }

    private func ruleRow(
        _ item: StandingSkillRuleControlItem,
        controls: StandingSkillRuleControlSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prepare every upcoming brief")
                        .font(.callout.weight(.semibold))
                    Text(ruleStatus(item, controls: controls))
                        .font(.caption)
                        .foregroundStyle(ruleStatusTint(item, controls: controls))
                        .accessibilityIdentifier("settings-standing-status")
                    Text(L10n.format(
                        "Up to %d briefs per day",
                        item.rule.maximumDailyExecutions))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(
                    "Automatic pre-meeting briefs",
                    isOn: ruleBinding(item))
                    .labelsHidden()
                    .accessibilityLabel("Automatic pre-meeting briefs")
                    .accessibilityIdentifier("settings-standing-enabled")
                    .disabled(
                        isBusy || externalMutationInFlight
                            || cannotChangeRule(item))
            }

            if deleteConfirmationID == item.id {
                Text(
                    "Delete this rule? Existing receipts and prepared briefs stay available for review."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Keep rule") { deleteConfirmationID = nil }
                        .accessibilityIdentifier(
                            "settings-standing-delete-cancel")
                    Button("Delete rule", role: .destructive) {
                        Task {
                            await mutate {
                                try await services
                                    .deleteStandingPreMeetingBriefRule(
                                        item.id,
                                        historyLimit: historyLimit)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-standing-delete-confirm")
                }
            } else {
                Button("Delete automatic action", role: .destructive) {
                    deleteConfirmationID = item.id
                }
                .accessibilityIdentifier("settings-standing-delete")
                .disabled(isBusy || externalMutationInFlight)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-standing-rule")
    }

    private func history(
        _ snapshot: StandingSkillAutomationCenterSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Automatic action history")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh automatic action history")
                .accessibilityIdentifier("settings-standing-history-refresh")
                .disabled(isBusy || externalMutationInFlight)
            }

            if snapshot.history.isEmpty {
                Text("No automatic briefs have run on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-standing-history-empty")
            } else {
                ForEach(snapshot.history) { receipt in
                    historyRow(receipt)
                }
                if snapshot.hasMoreHistory
                    && historyLimit
                        < StandingSkillAutomationCenterSnapshot
                            .maximumHistoryLimit {
                    Button("Show more automatic runs") {
                        historyLimit = StandingSkillAutomationCenterSnapshot
                            .maximumHistoryLimit
                        Task { await load() }
                    }
                    .accessibilityIdentifier("settings-standing-history-more")
                    .disabled(isBusy || externalMutationInFlight)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-standing-history")
    }

    private func historyRow(
        _ receipt: StandingSkillExecutionReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    historyStatus(receipt),
                    systemImage: historyIcon(receipt.record.state))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(historyTint(receipt.record.state))
                Spacer()
                Text(receipt.record.updatedAt, format: .dateTime
                    .month(.abbreviated).day().hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if receipt.hasArtifact {
                Button("Review prepared brief") {
                    Task { await loadBrief(receipt.record.proposalID) }
                }
                .accessibilityIdentifier(
                    "settings-standing-history-review-"
                        + receipt.record.proposalID.uuidString.lowercased())
                .disabled(isBusy || externalMutationInFlight)
            } else if receipt.record.state == .failed,
                      receipt.record.attempt
                        < StandingSkillExecutionPolicy.maximumAutomaticAttempts {
                Button("Retry preparation") {
                    Task { await retry(receipt.record.proposalID) }
                }
                .accessibilityIdentifier(
                    "settings-standing-history-retry-"
                        + receipt.record.proposalID.uuidString.lowercased())
                .disabled(isBusy || externalMutationInFlight)
            }
            if briefLoadFailedID == receipt.record.proposalID {
                Text("The prepared brief could not be verified.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "settings-standing-history-brief-error")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "settings-standing-history-"
                + receipt.record.proposalID.uuidString.lowercased())
    }

    private func ruleBinding(
        _ item: StandingSkillRuleControlItem
    ) -> Binding<Bool> {
        Binding(
            get: {
                snapshot?.controls.rules.first(where: { $0.id == item.id })?
                    .rule.isEnabled ?? false
            },
            set: { enabled in
                Task {
                    await mutate {
                        try await services.setStandingPreMeetingBriefRule(
                            item.id,
                            isEnabled: enabled,
                            historyLimit: historyLimit)
                    }
                }
            })
    }

    private func cannotChangeRule(
        _ item: StandingSkillRuleControlItem
    ) -> Bool {
        item.compatibility == .staleDefinition && !item.rule.isEnabled
    }

    private func ruleStatus(
        _ item: StandingSkillRuleControlItem,
        controls: StandingSkillRuleControlSnapshot
    ) -> String {
        if item.compatibility == .staleDefinition {
            return L10n.text("Needs review after an app update")
        }
        if !item.rule.isEnabled { return L10n.text("Off") }
        if controls.isPaused { return L10n.text("Paused with all actions") }
        if !item.isEffectivelyEnabled {
            return L10n.text("Blocked by the Pre-meeting brief action setting")
        }
        return L10n.text("On — prepares briefs in the final two hours")
    }

    private func ruleStatusTint(
        _ item: StandingSkillRuleControlItem,
        controls: StandingSkillRuleControlSnapshot
    ) -> Color {
        item.isEffectivelyEnabled ? .green
            : controls.isPaused || item.rule.isEnabled ? .orange : .secondary
    }

    private func historyStatus(
        _ receipt: StandingSkillExecutionReceipt
    ) -> String {
        let record = receipt.record
        return switch record.state {
        case .confirmed:
            L10n.text("Waiting to prepare")
        case .executing:
            L10n.text("Needs attention after interruption — not retried")
        case .succeeded:
            L10n.format("Brief ready — attempt %d", record.attempt)
        case .failed where
            record.attempt
                < StandingSkillExecutionPolicy.maximumAutomaticAttempts:
            L10n.format(
                "Retry available — attempt %d of %d",
                record.attempt,
                StandingSkillExecutionPolicy.maximumAutomaticAttempts)
        case .failed:
            L10n.text("Needs attention — retry limit reached")
        case .dismissed:
            L10n.text("Cancelled before preparation")
        case .proposed, .previewed:
            L10n.text("Unavailable")
        }
    }

    private func historyIcon(_ state: SkillExecutionState) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed, .executing: "exclamationmark.triangle.fill"
        case .dismissed: "xmark.circle"
        case .confirmed, .proposed, .previewed: "clock"
        }
    }

    private func historyTint(_ state: SkillExecutionState) -> Color {
        switch state {
        case .succeeded: .green
        case .failed, .executing: .orange
        case .dismissed, .confirmed, .proposed, .previewed: .secondary
        }
    }

    @MainActor
    private func load() async {
        guard !isMutating else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await services.loadStandingSkillAutomationCenter(
                historyLimit: historyLimit)
            loadFailed = false
            mutationFailed = false
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            loadFailed = true
        }
    }

    @MainActor
    private func mutate(
        _ operation: () async throws -> StandingSkillAutomationCenterSnapshot
    ) async {
        guard !isBusy, !externalMutationInFlight else { return }
        isMutating = true
        externalMutationInFlight = true
        mutationFailed = false
        deleteConfirmationID = nil
        do {
            snapshot = try await operation()
            loadFailed = false
            isMutating = false
            externalMutationInFlight = false
            didChangeExecutionAuthority()
        } catch is CancellationError {
            isMutating = false
            externalMutationInFlight = false
        } catch {
            if ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
                Self.logger.error(
                    "Disposable standing mutation failed: \(String(reflecting: error), privacy: .public)")
            }
            mutationFailed = true
            isMutating = false
            externalMutationInFlight = false
        }
    }

    @MainActor
    private func retry(_ proposalID: UUID) async {
        await mutate {
            try await services.retryStandingPreMeetingBrief(
                proposalID: proposalID,
                historyLimit: historyLimit)
        }
    }

    @MainActor
    private func loadBrief(_ proposalID: UUID) async {
        guard !isBusy, !externalMutationInFlight else { return }
        loadingBriefID = proposalID
        briefLoadFailedID = nil
        defer { loadingBriefID = nil }
        do {
            let brief = try await services.loadStandingPreMeetingBrief(
                proposalID: proposalID)
            guard !Task.isCancelled else { return }
            selectedBrief = StandingSkillBriefTarget(
                id: proposalID,
                brief: brief)
        } catch is CancellationError {
            return
        } catch {
            briefLoadFailedID = proposalID
        }
    }
}

private struct StandingSkillBriefSheet: View {
    @Environment(\.dismiss) private var dismiss
    let brief: MeetingBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Prepared brief", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            ScrollView {
                MeetingBriefArtifactView(brief: brief, openMeeting: nil)
            }
            .frame(maxHeight: 360)
            Label(
                "This brief stays in Portavoz on this Mac. Nothing was sent or shared.",
                systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("standing-brief-privacy")
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("standing-brief-close")
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standing-brief-sheet")
    }
}
