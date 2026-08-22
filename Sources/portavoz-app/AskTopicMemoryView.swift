import ApplicationKit
import PortavozCore
import SwiftUI

/// Explicit topic-memory query UI. The user chooses one canonical topic and
/// one factual job; no free-form question, model, or alias guess can select
/// graph authority.
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
            Label("Topic memory", systemImage: "checkmark.seal")
                .font(.title2.bold())
                .accessibilityIdentifier("ask-topic-title")
            Text(
                // swiftlint:disable:next line_length
                "Choose one confirmed topic and a memory view. Portavoz uses the exact identity you select and only shows source-backed facts you explicitly confirmed.")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(topic.label, systemImage: "number.circle.fill")
                    .font(.headline)
                    .accessibilityIdentifier("ask-topic-selected")
                Spacer()
                Button("Change") { model.clearTopicSelection() }
                    .accessibilityIdentifier("ask-topic-change")
            }
            jobPicker
            HStack {
                Spacer()
                Button(loadButtonTitle) {
                    model.loadSelectedTopicMemory()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state.outcome == .loading)
                .accessibilityIdentifier("ask-topic-load")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var jobPicker: some View {
        Picker(
            "Topic memory view",
            selection: Binding(
                get: { model.state.selectedJob },
                set: { model.selectJob($0) })) {
            Text("Current decisions")
                .tag(AskTopicMemoryJob.currentDecisions)
                .accessibilityIdentifier("ask-topic-job-current-decisions")
            Text("First confirmed discussion")
                .tag(AskTopicMemoryJob.firstConfirmedDiscussion)
                .accessibilityIdentifier("ask-topic-job-first-discussion")
            Text("Decision changes")
                .tag(AskTopicMemoryJob.decisionConflicts)
                .accessibilityIdentifier("ask-topic-job-decision-conflicts")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ask-topic-job")
    }

    private var loadButtonTitle: LocalizedStringKey {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Show current decisions"
        case .firstConfirmedDiscussion:
            "Show first confirmed discussion"
        case .decisionConflicts:
            "Show decision changes"
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.state.outcome {
        case .idle:
            EmptyView()
        case .loading:
            statusRow(
                loadingMessage,
                systemImage: nil,
                showsProgress: true)
        case .decisions(let decisions, let disclosure):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(decisions) { decision in
                    decisionCard(decision)
                }
                disclosureView(disclosure)
            }
        case .firstDiscussion(let discussion):
            firstDiscussionCard(discussion)
        case .conflicts(let conflicts, let disclosure):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(conflicts) { conflict in
                    conflictCard(conflict)
                }
                disclosureView(disclosure)
            }
        case .abstained(let reason):
            topicFailure(
                message: abstentionMessage(reason),
                identifier: "ask-topic-abstained")
        case .invalidEvidence:
            topicFailure(
                message: invalidEvidenceMessage,
                identifier: "ask-topic-invalid-evidence")
        case .unavailable:
            topicFailure(
                message: unavailableMessage,
                identifier: "ask-topic-unavailable")
        }
    }

    private var loadingMessage: String {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Loading confirmed decisions…"
        case .firstConfirmedDiscussion:
            "Loading the first confirmed discussion…"
        case .decisionConflicts:
            "Loading confirmed decision changes…"
        }
    }

    private var invalidEvidenceMessage: String {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Portavoz could not verify the returned decision evidence."
        case .firstConfirmedDiscussion:
            "Portavoz could not verify the first discussion evidence."
        case .decisionConflicts:
            "Portavoz could not verify the decision change evidence."
        }
    }

    private var unavailableMessage: String {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Could not load confirmed decisions."
        case .firstConfirmedDiscussion:
            "Could not load the first confirmed discussion."
        case .decisionConflicts:
            "Could not load confirmed decision changes."
        }
    }
}

extension AskTopicMemoryView {
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

    private func firstDiscussionCard(
        _ discussion: AskMemoryFirstDiscussion
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("First confirmed discussion", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text(discussion.meetingTitle)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier(
                    "ask-topic-first-discussion-\(discussion.id.rawValue.uuidString)")
            Text(L10n.format("Confirmed topic: %@", discussion.topicLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(discussion.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            Button {
                onOpenCitation(discussion.citation)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(
                        "\(discussion.meetingTitle) · \(AskMarkdown.clock(discussion.citation.timestamp))")
                        .lineLimit(1)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PVDesign.accent)
            .help(discussion.citation.text)
            .accessibilityIdentifier(
                "ask-topic-first-discussion-evidence-\(discussion.id.rawValue.uuidString)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func conflictCard(
        _ conflict: AskMemoryDecisionConflict
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirmed decision change", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Changed to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(conflict.successorStatement)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier(
                    "ask-topic-conflict-\(conflict.id.rawValue.uuidString)")
            Text("Replaced")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(conflict.replacedStatement)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "ask-topic-conflict-replaced-\(conflict.id.rawValue.uuidString)")
            Text(conflict.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            Text("Evidence")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(
                Array(orderedCitations(conflict).enumerated()),
                id: \.offset
            ) { index, citation in
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
                    "ask-topic-conflict-evidence-\(conflict.id.rawValue.uuidString)-\(index)")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func disclosureView(_ disclosure: AskMemoryDisclosure) -> some View {
        if disclosure.hasMore {
            switch model.state.selectedJob {
            case .currentDecisions:
                Label(
                    "More than 100 current decisions exist; this view shows the newest verified results.",
                    systemImage: "ellipsis.circle")
                    .accessibilityIdentifier("ask-topic-more-decisions")
            case .decisionConflicts:
                Label(
                    "More than 100 confirmed decision changes exist; this view shows the earliest verified results.",
                    systemImage: "ellipsis.circle")
                    .accessibilityIdentifier("ask-topic-more-conflicts")
            case .firstConfirmedDiscussion:
                EmptyView()
            }
        }
        if disclosure.omittedStaleCount > 0 {
            Label(
                omittedStaleMessage,
                systemImage: "clock")
                .accessibilityIdentifier("ask-topic-omitted-stale")
        }
        if disclosure.omittedUnavailableCount > 0 {
            Label(
                omittedUnavailableMessage,
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
            Button("Try again") { model.loadSelectedTopicMemory() }
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

    private func orderedCitations(
        _ conflict: AskMemoryDecisionConflict
    ) -> [AskCitation] {
        [conflict.primaryCitation] + conflict.citations.filter {
            $0.segmentID != conflict.primaryCitation.segmentID
        }
    }
}

extension AskTopicMemoryView {
    private func abstentionMessage(
        _ reason: MeetingMemoryGraphQueryAbstention
    ) -> String {
        switch reason {
        case .insufficientConfirmedDecision, .noMatchingFacts:
            noMatchingFactsMessage
        case .projectionNotReady:
            "Confirmed memory is still preparing. Try again shortly."
        case .topicUnavailable:
            "This confirmed topic is no longer available."
        case .staleEvidenceOnly, .evidenceUnavailable:
            unavailableEvidenceMessage
        case .projectionInconsistent:
            "Confirmed memory could not verify a complete projection yet."
        case .candidateBudgetExceeded:
            "The result is too large to verify safely."
        case .unsupportedConflict:
            noMatchingFactsMessage
        case .invalidQuery, .ambiguousPerson, .ambiguousTopic,
             .commitmentUnavailable, .personUnavailable,
             .noActiveCommitments, .unsupportedCausalLink,
             .missingTemporalBaseline:
            "The memory request was not specific enough to answer safely."
        }
    }

    private var noMatchingFactsMessage: String {
        switch model.state.selectedJob {
        case .currentDecisions:
            "No current confirmed decisions for this topic."
        case .firstConfirmedDiscussion:
            "No confirmed discussion is available for this topic."
        case .decisionConflicts:
            "No confirmed decision changes for this topic."
        }
    }

    private var unavailableEvidenceMessage: String {
        switch model.state.selectedJob {
        case .currentDecisions:
            "The matching decisions need current transcript evidence before Portavoz can show them."
        case .firstConfirmedDiscussion:
            "The first confirmed discussion needs current transcript evidence before Portavoz can show it."
        case .decisionConflicts:
            "The matching decision changes need current transcript evidence before Portavoz can show them."
        }
    }

    private var omittedStaleMessage: LocalizedStringKey {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Some decisions with outdated evidence were omitted."
        case .firstConfirmedDiscussion:
            "Some discussions with outdated evidence were omitted."
        case .decisionConflicts:
            "Some decision changes with outdated evidence were omitted."
        }
    }

    private var omittedUnavailableMessage: LocalizedStringKey {
        switch model.state.selectedJob {
        case .currentDecisions:
            "Some decisions without available evidence were omitted."
        case .firstConfirmedDiscussion:
            "Some discussions without available evidence were omitted."
        case .decisionConflicts:
            "Some decision changes without available evidence were omitted."
        }
    }
}
