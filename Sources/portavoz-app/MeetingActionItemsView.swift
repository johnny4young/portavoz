import ApplicationKit
import PortavozCore
import SwiftUI

/// Item-scoped controls and exact evidence stay separate from the generated
/// document shell so adding a reviewed effect cannot grow that owner without
/// bound.
struct MeetingActionItemsView: View {
    let values: MeetingGeneratedDocumentValues
    let actions: MeetingGeneratedDocumentActions

    @State private var editingCandidate: CommitmentInboxCandidate?
    @State private var processingID: UUID?

    private var evidenceByItem: [UUID: [SummaryActionItemEvidence]] {
        Dictionary(
            grouping: values.summary.draft.actionItemEvidence,
            by: \.actionItemID)
    }

    private var pendingCandidateByItem: [UUID: CommitmentInboxCandidate] {
        let pending = (values.commitmentInbox?.candidates ?? []).filter {
            if case .pending = $0.status { return true }
            return false
        }
        return Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(values.summary.draft.actionItems) { item in
                let pending = pendingCandidateByItem[item.id]
                VStack(alignment: .leading, spacing: 6) {
                    actionRow(item, pending: pending)
                    evidence(for: item)
                }
            }
        }
        .sheet(item: $editingCandidate) { candidate in
            if let inbox = values.commitmentInbox, let commitmentActions = actions.commitmentActions {
                MeetingCommitmentConfirmationSheet(
                    candidate: candidate,
                    ownerChoices: inbox.ownerChoices,
                    cancel: { editingCandidate = nil },
                    confirm: { title, assignee, dueAt in
                        await commitmentActions.confirm(candidate, title, assignee, dueAt)
                    })
            }
        }
    }

    private func actionRow(_ item: ActionItem, pending: CommitmentInboxCandidate?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: actionItemBinding(item)) {
                Text(item.text).strikethrough(item.isDone)
            }
            .toggleStyle(.pvCheckbox)
            .accessibilityIdentifier("action-item-\(item.id.uuidString)")
            Spacer(minLength: 8)
            if let pending, let commitmentActions = actions.commitmentActions {
                pendingControls(pending, commitmentActions: commitmentActions)
            }
            if canCreateGitHubIssue(item) {
                Button("Create GitHub issue") {
                    actions.createGitHubIssue(item)
                }
                .controlSize(.small)
                .accessibilityIdentifier(
                    "action-item-\(item.id.uuidString)-github")
                .help(
                    // Keep this as one literal so localization validation sees it.
                    "Review the repository, the issue body and its sources before sending.")
            }
        }
    }

    private func pendingControls(
        _ candidate: CommitmentInboxCandidate,
        commitmentActions: MeetingCommitmentInboxActions
    ) -> some View {
        let canConfirm = candidate.evidence.status == .current && !candidate.evidence.segments.isEmpty
        return HStack(spacing: 6) {
            Text("Suggested")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PVDesign.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PVDesign.accent.opacity(0.12), in: Capsule())
            Button("Review and confirm…") {
                editingCandidate = candidate
            }
            .buttonStyle(.pvPrimary)
            .controlSize(.mini)
            .disabled(!canConfirm || processingID != nil)
            .help(canConfirm
                ? L10n.text("Review the wording, owner, deadline, and source before confirming.")
                : L10n.text("Regenerate the summary before confirming this stale source."))
            .accessibilityIdentifier("action-item-\(candidate.id.uuidString)-confirm")
            Menu("Review later") {
                Button("Tomorrow") {
                    deferCandidate(candidate, days: 1, actions: commitmentActions)
                }
                .accessibilityIdentifier("action-item-\(candidate.id.uuidString)-defer-tomorrow")
                Button("Next week") {
                    deferCandidate(candidate, days: 7, actions: commitmentActions)
                }
                .accessibilityIdentifier("action-item-\(candidate.id.uuidString)-defer-week")
            }
            .controlSize(.mini)
            .fixedSize()
            .disabled(processingID == candidate.id)
            .accessibilityIdentifier("action-item-\(candidate.id.uuidString)-defer")
            Button("Dismiss", role: .destructive) {
                perform(candidate) { await commitmentActions.dismiss(candidate) }
            }
            .controlSize(.mini)
            .disabled(processingID == candidate.id)
            .accessibilityIdentifier("action-item-\(candidate.id.uuidString)-dismiss")
        }
    }

    private func deferCandidate(
        _ candidate: CommitmentInboxCandidate,
        days: Int,
        actions commitmentActions: MeetingCommitmentInboxActions
    ) {
        perform(candidate) { await commitmentActions.deferCandidate(candidate, days: days) }
    }

    /// Failures surface through the detail model's action error.
    private func perform(
        _ candidate: CommitmentInboxCandidate,
        operation: @escaping @MainActor () async -> Bool
    ) {
        processingID = candidate.id
        Task { @MainActor in
            _ = await operation()
            processingID = nil
        }
    }

    @ViewBuilder
    private func evidence(for item: ActionItem) -> some View {
        if let evidence = evidenceByItem[item.id]?.only {
            let resolution = currentResolution(evidence.resolveEvidence(
                currentTranscriptRevision: values.transcriptRevision,
                segments: values.segments))
            MeetingEvidenceSources(
                resolution: resolution,
                sourceIdentifier:
                    "summary-action-item-\(item.id.uuidString)-evidence",
                staleIdentifier:
                    "summary-action-item-\(item.id.uuidString)-stale",
                unavailableIdentifier:
                    "summary-action-item-\(item.id.uuidString)-unavailable",
                clock: { values.presentation.clock($0) },
                focus: actions.focusEvidence)
        }
    }

    private func canCreateGitHubIssue(_ item: ActionItem) -> Bool {
        guard !item.isDone,
              values.freshness == .current,
              let evidence = evidenceByItem[item.id]?.only
        else { return false }
        return evidence.resolveEvidence(
            currentTranscriptRevision: values.transcriptRevision,
            segments: values.segments).status == .current
    }

    private func actionItemBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { actions.setActionItem(item, $0) })
    }

    private func currentResolution(
        _ resolution: TranscriptEvidenceResolution
    ) -> TranscriptEvidenceResolution {
        values.freshness == .current
            ? resolution
            : TranscriptEvidenceResolution(status: .stale)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
