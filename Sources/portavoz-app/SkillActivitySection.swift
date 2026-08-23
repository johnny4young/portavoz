import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI

enum SkillActivityPresentationState: Equatable {
    case loading
    case unavailable
    case empty
    case receipts

    init(
        receiptScope: SkillExecutionReviewScope,
        receiptSkillID: String? = nil,
        receiptPeriod: SkillExecutionReviewPeriod = .anytime,
        snapshot: SkillControlCenterSnapshot?,
        isLoading: Bool,
        loadFailed: Bool
    ) {
        if isLoading {
            self = .loading
            return
        }
        guard let snapshot,
              snapshot.receiptScope == receiptScope,
              snapshot.receiptSkillID == receiptSkillID,
              snapshot.receiptPeriod == receiptPeriod
        else {
            self = loadFailed ? .unavailable : .loading
            return
        }
        guard !loadFailed, snapshot.receiptLoadState == .verified else {
            self = .unavailable
            return
        }
        self = snapshot.receipts.isEmpty ? .empty : .receipts
    }

    var allowsExplicitRefresh: Bool {
        self == .empty || self == .receipts
    }

    func allowsFilterReset(hasActiveFilters: Bool) -> Bool {
        self == .empty && hasActiveFilters
    }
}

/// Keeps receipt browsing explicit and bounded. The initial projection stays
/// cheap; one user action may widen it only to ApplicationKit's existing hard
/// ceiling, and changing scope or exact Skill returns to the cheap window.
struct SkillActivityHistoryWindow: Equatable {
    private(set) var requestedLimit =
        SkillControlCenterSnapshot.defaultReceiptLimit

    var isExpanded: Bool {
        requestedLimit == SkillControlCenterSnapshot.maximumReceiptLimit
    }

    func canExpand(hasMoreReceipts: Bool) -> Bool {
        requestedLimit < SkillControlCenterSnapshot.maximumReceiptLimit
            && hasMoreReceipts
    }

    mutating func expand() {
        requestedLimit = SkillControlCenterSnapshot.maximumReceiptLimit
    }

    mutating func reset() {
        requestedLimit = SkillControlCenterSnapshot.defaultReceiptLimit
    }
}

/// D336/D373/D374 — one status-, exact-Skill-, and update-period-scoped review.
///
/// The returned snapshot must match every selected lens before this view shows
/// any row. Loading and failures cannot relabel stale evidence.
struct SkillActivitySection: View {
    @Binding var receiptScope: SkillExecutionReviewScope
    @Binding var receiptSkillID: String?
    @Binding var receiptPeriod: SkillExecutionReviewPeriod
    @FocusState private var focusedReceiptID: UUID?
    @AccessibilityFocusState private var accessibilityFocusedReceiptID: UUID?

    let snapshot: SkillControlCenterSnapshot?
    let skills: [SkillControlCenterItem]
    let isLoading: Bool
    let isMutating: Bool
    let loadFailed: Bool
    let focusRequestID: UUID?
    let historyWindow: SkillActivityHistoryWindow
    let retry: () -> Void
    let refresh: () -> Void
    let clearFilters: () -> Void
    let showMore: () -> Void
    let inspectReceipt: (SkillControlCenterReceipt) -> Void

    var body: some View {
        Group {
            scopePicker
            skillFilter
            SkillActivityPeriodFilter(
                receiptPeriod: $receiptPeriod,
                isDisabled: isLoading || isMutating)

            if presentationState.allowsExplicitRefresh {
                Button(action: refresh) {
                    Label("Refresh activity", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(
                    "settings-skills-receipt-refresh")
                .disabled(isLoading || isMutating)
            }

            switch presentationState {
            case .loading:
                loadingContent
            case .unavailable:
                unavailableContent
            case .empty:
                emptyContent
                if presentationState.allowsFilterReset(
                    hasActiveFilters: hasActiveFilters
                ) {
                    Button("Clear activity filters", action: clearFilters)
                        .accessibilityIdentifier(
                            "settings-skills-receipt-clear-filters")
                        .disabled(isLoading || isMutating)
                }
            case .receipts:
                ForEach(snapshot?.receipts ?? []) { receipt in
                    receiptRow(receipt)
                }
                if historyWindow.canExpand(
                    hasMoreReceipts: snapshot?.hasMoreReceipts ?? false
                ) {
                    Button("Show more runs", action: showMore)
                        .accessibilityIdentifier(
                            "settings-skills-receipt-show-more")
                        .disabled(isLoading || isMutating)
                }
                Text(L10n.format(
                    "Each view shows up to %d matching runs on this Mac.",
                    historyWindow.requestedLimit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "settings-skills-receipt-history-limit")
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
        .task(id: accessibilityAnnouncement) {
            guard let accessibilityAnnouncement else { return }
            SkillActivityAccessibilityAnnouncement.post(
                accessibilityAnnouncement)
        }
    }

    private var presentationState: SkillActivityPresentationState {
        SkillActivityPresentationState(
            receiptScope: receiptScope,
            receiptSkillID: receiptSkillID,
            receiptPeriod: receiptPeriod,
            snapshot: snapshot,
            isLoading: isLoading,
            loadFailed: loadFailed)
    }

    private var skillFilter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Action")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("All actions") {
                    receiptSkillID = nil
                }
                .accessibilityIdentifier(
                    "settings-skills-receipt-skill-all")

                ForEach(
                    skills.filter { $0.availability == .available }
                ) { skill in
                    Button {
                        receiptSkillID = skill.id
                    } label: {
                        Text(SkillReceiptPresentation.skillTitle(skill.id))
                    }
                    .accessibilityIdentifier(
                        "settings-skills-receipt-skill-\(skill.id)")
                }
            } label: {
                Text(selectedSkillTitle)
                    .lineLimit(1)
                    .frame(minWidth: 180, alignment: .leading)
            }
            .accessibilityLabel("Filter history by action")
            .accessibilityValue(selectedSkillTitle)
            .accessibilityIdentifier(
                "settings-skills-receipt-skill-filter")
            .disabled(isLoading || isMutating || skills.isEmpty)
        }
    }

    private var selectedSkillTitle: String {
        guard let receiptSkillID else { return L10n.text("All actions") }
        return SkillReceiptPresentation.skillTitle(receiptSkillID)
    }

    private var hasActiveFilters: Bool {
        receiptSkillID != nil || receiptPeriod != .anytime
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

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading receipt history…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-skills-receipt-scope-loading")
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Receipt history is unavailable",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("The selected activity view could not be verified. No runs are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-skills-receipt-scope-error")
            Button("Try again", action: retry)
                .accessibilityIdentifier(
                    "settings-skills-receipt-scope-retry")
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

    private var emptyTitle: String {
        return switch receiptScope {
        case .recent: L10n.text("No recent action runs")
        case .waiting: L10n.text("No waiting action runs")
        case .needsAttention: L10n.text("No action runs needing attention")
        case .completed: L10n.text("No completed action runs")
        }
    }

    private var emptyDetail: String {
        if receiptPeriod != .anytime {
            if let receiptSkillID {
                return L10n.format(
                    "No %@ runs match the selected time period.",
                    SkillReceiptPresentation.skillTitle(receiptSkillID))
            }
            return L10n.text(
                "No runs match the selected time period.")
        }
        if let receiptSkillID {
            return L10n.format(
                "No %@ runs match this activity view.",
                SkillReceiptPresentation.skillTitle(receiptSkillID))
        }
        return switch receiptScope {
        case .recent:
            L10n.text("A receipt appears here only after you confirm an action.")
        case .waiting:
            L10n.text("Confirmed runs appear here until execution begins.")
        case .needsAttention:
            L10n.text("Interrupted and failed runs appear here for review.")
        case .completed:
            L10n.text("Successful and pre-handoff cancelled runs appear here.")
        }
    }

    private var accessibilityAnnouncement: String? {
        switch presentationState {
        case .unavailable:
            [
                L10n.text("Receipt history is unavailable"),
                L10n.text(
                    "The selected activity view could not be verified. No runs are shown.")
            ].joined(separator: ". ")
        case .empty:
            [emptyTitle, emptyDetail].joined(separator: ". ")
        case .loading, .receipts:
            nil
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

@MainActor
private enum SkillActivityAccessibilityAnnouncement {
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
    }
}
