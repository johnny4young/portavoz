import ApplicationKit
import PortavozCore
import SwiftUI

/// Inline result for one exact commitment already returned by the confirmed
/// person lane. It renders typed graph facts and exact transcript evidence;
/// absence and operational failure remain visibly distinct.
struct AskMemoryBlockersView: View {
    let outcome: AskMemoryBlockerOutcome
    let onRetry: () -> Void
    let onOpenCitation: (AskCitation) -> Void

    @ViewBuilder
    var body: some View {
        switch outcome {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                "Loading confirmed active blockers…",
                systemImage: nil,
                showsProgress: true)
        case .facts(let blockers, let disclosure):
            VStack(alignment: .leading, spacing: 10) {
                Label("Active blockers", systemImage: "exclamationmark.octagon.fill")
                    .font(.subheadline.weight(.semibold))
                ForEach(blockers) { blocker in
                    blockerCard(blocker)
                }
                disclosureView(disclosure)
            }
        case .abstained(let reason):
            failure(
                message: abstentionMessage(reason),
                identifier: "ask-memory-blockers-abstained")
        case .invalidEvidence:
            failure(
                message: "Portavoz could not verify the blocker evidence.",
                identifier: "ask-memory-blockers-invalid-evidence")
        case .unavailable:
            failure(
                message: "Could not load confirmed active blockers.",
                identifier: "ask-memory-blockers-unavailable")
        }
    }

    private func blockerCard(_ blocker: AskMemoryBlocker) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(blocker.decisionStatement, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier(
                    "ask-memory-blocker-\(blocker.id.rawValue.uuidString)")
            Text(L10n.format("Blocks: %@", blocker.commitmentTitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "ask-memory-blocker-commitment-\(blocker.id.rawValue.uuidString)")
            Text(blocker.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(orderedCitations(blocker).enumerated()), id: \.offset) { index, citation in
                Button {
                    onOpenCitation(citation)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(
                            "\(citation.meetingTitle) · \(AskMarkdown.clock(citation.timestamp))")
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .help(citation.text)
                .accessibilityIdentifier(
                    "ask-memory-blocker-evidence-\(blocker.id.rawValue.uuidString)-\(index)")
            }
        }
        .padding(10)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func disclosureView(_ disclosure: AskMemoryDisclosure) -> some View {
        if disclosure.hasMore {
            Label(
                "More than 100 active blockers exist; this view shows the newest verified results.",
                systemImage: "ellipsis.circle")
                .accessibilityIdentifier("ask-memory-blockers-more")
        }
        if disclosure.omittedStaleCount > 0 {
            Label(
                "Some blockers with outdated evidence were omitted.",
                systemImage: "clock")
                .accessibilityIdentifier("ask-memory-blockers-omitted-stale")
        }
        if disclosure.omittedUnavailableCount > 0 {
            Label(
                "Some blockers without available evidence were omitted.",
                systemImage: "exclamationmark.shield")
                .accessibilityIdentifier("ask-memory-blockers-omitted-unavailable")
        }
    }

    private func failure(message: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                message,
                systemImage: "exclamationmark.triangle",
                identifier: identifier)
            Button("Try again", action: onRetry)
                .accessibilityIdentifier("ask-memory-blockers-retry")
        }
    }

    private func statusRow(
        _ message: String,
        systemImage: String?,
        showsProgress: Bool = false,
        identifier: String = "ask-memory-blockers-status"
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(L10n.text(message))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func orderedCitations(
        _ blocker: AskMemoryBlocker
    ) -> [AskCitation] {
        [blocker.primaryCitation] + blocker.citations.filter {
            $0.segmentID != blocker.primaryCitation.segmentID
        }
    }

    private func abstentionMessage(
        _ reason: MeetingMemoryGraphQueryAbstention
    ) -> String {
        switch reason {
        case .unsupportedCausalLink, .noMatchingFacts, .noActiveCommitments:
            "No confirmed active blockers for this commitment."
        case .commitmentUnavailable:
            "This commitment is no longer available."
        case .projectionNotReady:
            "Confirmed memory is still preparing. Try again shortly."
        case .staleEvidenceOnly, .evidenceUnavailable:
            "The matching blockers need current transcript evidence before Portavoz can show them."
        case .projectionInconsistent:
            "Confirmed memory could not verify a complete projection yet."
        case .candidateBudgetExceeded:
            "The result is too large to verify safely."
        case .invalidQuery, .personUnavailable, .ambiguousPerson,
             .topicUnavailable, .ambiguousTopic, .unsupportedConflict,
             .missingTemporalBaseline, .insufficientConfirmedDecision:
            "The memory request was not specific enough to answer safely."
        }
    }
}
