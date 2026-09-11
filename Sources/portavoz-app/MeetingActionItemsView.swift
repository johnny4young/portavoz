import ApplicationKit
import PortavozCore
import SwiftUI

/// Item-scoped controls and exact evidence stay separate from the generated
/// document shell so adding a reviewed effect cannot grow that owner without
/// bound.
struct MeetingActionItemsView: View {
    let values: MeetingGeneratedDocumentValues
    let actions: MeetingGeneratedDocumentActions

    private var evidenceByItem: [UUID: [SummaryActionItemEvidence]] {
        Dictionary(
            grouping: values.summary.draft.actionItemEvidence,
            by: \.actionItemID)
    }

    var body: some View {
        ForEach(values.summary.draft.actionItems) { item in
            VStack(alignment: .leading, spacing: 6) {
                actionRow(item)
                evidence(for: item)
            }
        }
    }

    private func actionRow(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: actionItemBinding(item)) {
                Text(item.text).strikethrough(item.isDone)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("action-item-\(item.id.uuidString)")
            Spacer(minLength: 8)
            if canCreateGitHubIssue(item) {
                Button("Create GitHub issue") {
                    actions.createGitHubIssue(item)
                }
                .controlSize(.small)
                .accessibilityIdentifier(
                    "action-item-\(item.id.uuidString)-github")
                .help(
                    // Keep this as one literal so localization validation sees it.
                    "Review the repository, exact issue body, and transcript evidence before anything leaves this Mac.")
            }
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
