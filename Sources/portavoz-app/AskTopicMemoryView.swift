import ApplicationKit
import PortavozCore
import SwiftUI

/// Explicit confirmed-decision query UI. The user chooses one canonical topic;
/// no free-form question, model, or alias guess can select graph authority.
struct AskTopicMemoryView: View {
    let model: AskTopicMemoryModel
    let onOpenCitation: (AskCitation) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                topicSearch
                if let selected = model.state.selectedTopic {
                    selectedTopic(selected)
                    outcome
                } else {
                    topicResults
                }
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Current decisions", systemImage: "checkmark.seal")
                .font(.title2.bold())
                .accessibilityIdentifier("ask-topic-title")
            Text(
                // swiftlint:disable:next line_length
                "Choose one confirmed topic. Portavoz uses the exact identity you select and shows only current decisions you explicitly confirmed about it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topicSearch: some View {
        TextField(
            "Find a confirmed topic…",
            text: Binding(
                get: { model.state.topicQuery },
                set: { model.updateTopicQuery($0) }))
            .textFieldStyle(.roundedBorder)
            .disabled(model.state.selectedTopic != nil)
            .accessibilityIdentifier("ask-topic-search")
    }

    @ViewBuilder
    private var topicResults: some View {
        switch model.state.topicsPhase {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                "Searching confirmed topics…",
                systemImage: nil,
                showsProgress: true)
        case .empty:
            statusRow(
                "No confirmed topics match this search.",
                systemImage: "questionmark.folder")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    "Could not search confirmed topics.",
                    systemImage: "exclamationmark.triangle")
                Button("Try again") { model.retryTopicSearch() }
                    .accessibilityIdentifier("ask-topic-search-retry")
            }
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.state.topics) { topic in
                    Button {
                        model.selectTopic(topic.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "number")
                            Text(topic.label)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .accessibilityIdentifier(
                        "ask-topic-option-\(topic.id.rawValue.uuidString)")
                }
                if model.state.topicsHaveMore {
                    Label(
                        "More topics match. Refine the name to choose the right one.",
                        systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ask-topic-overflow")
                }
            }
        }
    }

    private func selectedTopic(_ topic: AskMemoryTopic) -> some View {
        HStack(spacing: 10) {
            Label(topic.label, systemImage: "number.circle.fill")
                .font(.headline)
                .accessibilityIdentifier("ask-topic-selected")
            Spacer()
            Button("Change") { model.clearTopicSelection() }
                .accessibilityIdentifier("ask-topic-change")
            Button("Show current decisions") {
                model.loadSelectedTopicDecisions()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state.outcome == .loading)
            .accessibilityIdentifier("ask-topic-load")
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.state.outcome {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                "Loading confirmed decisions…",
                systemImage: nil,
                showsProgress: true)
        case .facts(let decisions, let disclosure):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(decisions) { decision in
                    decisionCard(decision)
                }
                disclosureView(disclosure)
            }
        case .abstained(let reason):
            topicFailure(
                message: abstentionMessage(reason),
                identifier: "ask-topic-abstained")
        case .invalidEvidence:
            topicFailure(
                message: "Portavoz could not verify the returned decision evidence.",
                identifier: "ask-topic-invalid-evidence")
        case .unavailable:
            topicFailure(
                message: "Could not load confirmed decisions.",
                identifier: "ask-topic-unavailable")
        }
    }

    private func decisionCard(_ decision: AskMemoryDecision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(decision.statement, systemImage: "checkmark.seal.fill")
                .font(.headline)
                .accessibilityIdentifier(
                    "ask-topic-decision-\(decision.id.rawValue.uuidString)")
            Text(L10n.format("Confirmed about %@", decision.topicLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(decision.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(orderedCitations(decision).enumerated()), id: \.offset) { index, citation in
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
                    "ask-topic-evidence-\(decision.id.rawValue.uuidString)-\(index)")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func disclosureView(_ disclosure: AskMemoryDisclosure) -> some View {
        if disclosure.hasMore {
            Label(
                "More than 100 current decisions exist; this view shows the newest verified results.",
                systemImage: "ellipsis.circle")
                .accessibilityIdentifier("ask-topic-more-decisions")
        }
        if disclosure.omittedStaleCount > 0 {
            Label(
                "Some decisions with outdated evidence were omitted.",
                systemImage: "clock")
                .accessibilityIdentifier("ask-topic-omitted-stale")
        }
        if disclosure.omittedUnavailableCount > 0 {
            Label(
                "Some decisions without available evidence were omitted.",
                systemImage: "exclamationmark.shield")
                .accessibilityIdentifier("ask-topic-omitted-unavailable")
        }
    }

    private func topicFailure(message: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                message,
                systemImage: "exclamationmark.triangle",
                identifier: identifier)
            Button("Try again") { model.loadSelectedTopicDecisions() }
                .accessibilityIdentifier("ask-topic-load-retry")
        }
    }

    private func statusRow(
        _ message: String,
        systemImage: String?,
        showsProgress: Bool = false,
        identifier: String = "ask-topic-status"
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
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func orderedCitations(
        _ decision: AskMemoryDecision
    ) -> [AskCitation] {
        [decision.primaryCitation] + decision.citations.filter {
            $0.segmentID != decision.primaryCitation.segmentID
        }
    }

    private func abstentionMessage(
        _ reason: MeetingMemoryGraphQueryAbstention
    ) -> String {
        switch reason {
        case .insufficientConfirmedDecision, .noMatchingFacts:
            "No current confirmed decisions for this topic."
        case .projectionNotReady:
            "Confirmed memory is still preparing. Try again shortly."
        case .topicUnavailable:
            "This confirmed topic is no longer available."
        case .staleEvidenceOnly, .evidenceUnavailable:
            "The matching decisions need current transcript evidence before Portavoz can show them."
        case .projectionInconsistent:
            "Confirmed memory could not verify a complete projection yet."
        case .candidateBudgetExceeded:
            "The result is too large to verify safely."
        case .invalidQuery, .ambiguousPerson, .ambiguousTopic,
             .commitmentUnavailable, .personUnavailable,
             .noActiveCommitments, .unsupportedCausalLink,
             .unsupportedConflict, .missingTemporalBaseline:
            "The memory request was not specific enough to answer safely."
        }
    }
}
