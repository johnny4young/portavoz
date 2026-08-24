import ApplicationKit
import Foundation
import SwiftUI

/// "Ask your meetings": one storage-independent presentation model renders
/// conversation state and sends questions through the shared application
/// workflow. Citations navigate to the exact meeting moment.
struct AskView: View {
    let model: AskModel
    let onOpenCitation: (AskCitation) -> Void

    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.memory != nil || model.topicMemory != nil {
                surfacePicker
                Divider()
            }
            switch model.state.surface {
            case .conversation:
                conversation
            case .personCommitments:
                if let memory = model.memory {
                    AskMemoryView(
                        model: memory,
                        onOpenCitation: onOpenCitation)
                }
            case .topicDecisions:
                if let topicMemory = model.topicMemory {
                    AskTopicMemoryView(
                        model: topicMemory,
                        onOpenCitation: onOpenCitation)
                }
            }
        }
        .navigationTitle("Ask your meetings")
        .onAppear {
            questionFocused = model.state.surface == .conversation
            if model.state.surface == .personCommitments {
                model.memory?.activate()
            } else if model.state.surface == .topicDecisions {
                model.topicMemory?.activate()
            }
        }
        .onChange(of: model.state.surface) { _, surface in
            questionFocused = surface == .conversation
        }
        .onDisappear { model.cancelAllWork() }
    }

    @ViewBuilder
    private var conversation: some View {
        sourcePolicy
        Divider()
        if model.state.exchanges.isEmpty && !model.state.isAsking {
            ContentUnavailableView(
                "Ask your meetings",
                systemImage: "bubble.left.and.text.bubble.right",
                // One-line UI copy.
                // swiftlint:disable:next line_length
                description: Text("Questions like \"what did we agree about the budget?\" — answered on your Mac, citing meeting and moment."))
        } else {
            exchangeList
        }
        inputBar
    }

    private var surfacePicker: some View {
        Picker(
            "Ask view",
            selection: Binding(
                get: { model.state.surface },
                set: { model.selectSurface($0) })) {
            Text("Ask")
                .tag(AskModel.Surface.conversation)
                .accessibilityIdentifier("ask-surface-conversation")
            Text("By person")
                .tag(AskModel.Surface.personCommitments)
                .accessibilityIdentifier("ask-surface-person-commitments")
            Text("By topic")
                .tag(AskModel.Surface.topicDecisions)
                .accessibilityIdentifier("ask-surface-topic-decisions")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 480)
        .padding(10)
        .accessibilityIdentifier("ask-surface")
    }

    private var exchangeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.state.exchanges) { exchange in
                        exchangeView(exchange)
                    }
                    if model.state.isAsking,
                       let question = model.state.pendingQuestion,
                       let source = model.state.pendingSource,
                       let phase = model.state.pendingPhase {
                        pendingExchange(
                            question: question,
                            source: source,
                            citations: model.state.pendingCitations,
                            answerText: model.state.pendingAnswerText,
                            phase: phase)
                        .id("asking")
                    }
                }
                .padding(16)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .onChange(of: model.state.exchanges.count) { _, _ in
                if let last = model.state.exchanges.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func pendingExchange(
        question: String,
        source: AskModel.ExchangeSource,
        citations: [AskCitation],
        answerText: String?,
        phase: AskModel.PendingPhase
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.callout.weight(.semibold))
                .padding(10)
                .background(
                    PVDesign.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("ask-pending-question")
            sourceBadge(source, identifier: "ask-pending-source")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progressText(for: phase))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(progressIdentifier(for: phase))
                Spacer()
                Button("Cancel") {
                    model.cancelPendingAnswer()
                }
                .buttonStyle(.plain)
                .foregroundStyle(PVDesign.accent)
                .accessibilityIdentifier("ask-cancel")
            }
            if !citations.isEmpty {
                Text("Evidence available now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                citationButtons(
                    citations,
                    identifierPrefix: "ask-pending-citation")
            }
            if let answerText {
                Text(answerText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ask-pending-answer")
            }
        }
    }

    private func exchangeView(_ exchange: AskModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.callout.weight(.semibold))
                .padding(10)
                .background(PVDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            sourceBadge(exchange.source, identifier: "ask-exchange-source")
            Text(exchange.answer)
                .textSelection(.enabled)
                .accessibilityIdentifier("ask-answer-\(exchange.id.uuidString)")
            if let status = AskAnswerPresentation.statusText(
                for: exchange.generationOutcome,
                hasCitations: !exchange.citations.isEmpty
            ) {
                Label(status, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "ask-generation-\(exchange.generationOutcome.rawValue)")
            }
            if !exchange.citations.isEmpty {
                Text("Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                citationButtons(
                    exchange.citations,
                    identifierPrefix: "ask-citation-\(exchange.id.uuidString)")
            }
        }
        .id(exchange.id)
    }

    @ViewBuilder
    private func citationButtons(
        _ citations: [AskCitation],
        identifierPrefix: String
    ) -> some View {
        ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
            Button {
                onOpenCitation(citation)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text("\(citation.meetingTitle) · \(AskMarkdown.clock(citation.timestamp))")
                        .lineLimit(1)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PVDesign.accent)
            .help(citation.text)
            .accessibilityIdentifier("\(identifierPrefix)-\(index)")
        }
    }

    private func progressText(for phase: AskModel.PendingPhase) -> LocalizedStringKey {
        switch phase {
        case .findingEvidence:
            "Finding exact evidence…"
        case .refiningEvidence:
            "Exact evidence found — checking related meaning…"
        case .generatingAnswer:
            "Evidence ready — generating answer…"
        }
    }

    private func progressIdentifier(for phase: AskModel.PendingPhase) -> String {
        switch phase {
        case .findingEvidence:
            "ask-progress-finding"
        case .refiningEvidence:
            "ask-progress-refining"
        case .generatingAnswer:
            "ask-progress-generating"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                "Ask about your meetings…",
                text: Binding(
                    get: { model.state.draft },
                    set: { model.updateDraft($0) }))
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .onSubmit { model.submit() }
                .accessibilityIdentifier("ask-question-field")
            Button {
                model.submit()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(
                model.state.draft.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                    || !hasResolvedSource)
            .accessibilityIdentifier("ask-submit")
        }
        .padding(12)
    }

    private var sourcePolicy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Answer sources",
                selection: Binding(
                    get: { model.state.sourceMode },
                    set: { model.selectSourceMode($0) })) {
                Label("Library", systemImage: "books.vertical")
                    .tag(AskModel.SourceMode.library)
                    .accessibilityIdentifier("ask-source-library")
                Label("Meeting", systemImage: "person.2")
                    .tag(AskModel.SourceMode.meeting)
                    .accessibilityIdentifier("ask-source-meeting")
                Label("Web", systemImage: "globe")
                    .tag(AskModel.SourceMode.web)
                    .accessibilityIdentifier("ask-source-web")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .accessibilityIdentifier("ask-source-picker")

            sourcePolicyStatus
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sourcePolicyStatus: some View {
        switch model.state.sourceMode {
        case .library:
            Label(
                "Only your local meeting library will be searched.",
                systemImage: "lock")
                .accessibilityIdentifier("ask-source-status-library")
        case .meeting:
            meetingSourceStatus
        case .web:
            Label(
                "Web answers are not available yet. Nothing else will be searched.",
                systemImage: "network.slash")
                .accessibilityIdentifier("ask-source-status-web-unavailable")
        }
    }

    @ViewBuilder
    private var meetingSourceStatus: some View {
        switch model.state.sourceCatalogState {
        case .idle:
            ProgressView()
                .controlSize(.small)
                .task { model.loadSourceMeetingsIfNeeded() }
                .accessibilityIdentifier("ask-source-meetings-loading")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading local meetings…")
            }
            .accessibilityIdentifier("ask-source-meetings-loading")
        case .failed:
            HStack(spacing: 8) {
                Label("Meeting list unavailable.", systemImage: "exclamationmark.triangle")
                Button("Try again") { model.retrySourceMeetings() }
                    .accessibilityIdentifier("ask-source-meetings-retry")
            }
            .accessibilityIdentifier("ask-source-meetings-failed")
        case .loaded:
            if model.state.sourceMeetings.isEmpty {
                Label("No local meetings are available.", systemImage: "tray")
                    .accessibilityIdentifier("ask-source-meetings-empty")
            } else {
                Menu {
                    ForEach(model.state.sourceMeetings) { meeting in
                        Button(meetingLabel(meeting)) {
                            model.selectSourceMeeting(meeting.id)
                        }
                        .accessibilityIdentifier(
                            "ask-source-meeting-option-\(meeting.id.rawValue.uuidString)")
                    }
                } label: {
                    Label(selectedMeetingTitle ?? "Choose a meeting", systemImage: "calendar")
                }
                .accessibilityIdentifier("ask-source-meeting-picker")
            }
        }
    }

    @ViewBuilder
    private func sourceBadge(
        _ source: AskModel.ExchangeSource,
        identifier: String
    ) -> some View {
        switch source {
        case .library:
            Label("Source: Library", systemImage: "books.vertical")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier)-library")
        case .meeting(_, let title):
            Label("Source: \(title)", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier)-meeting")
        }
    }

    private var selectedMeetingTitle: String? {
        guard let selected = model.state.selectedSourceMeetingID else {
            return nil
        }
        return model.state.sourceMeetings.first(where: { $0.id == selected }).map(
            meetingLabel)
    }

    private func meetingLabel(_ meeting: AskSourceMeetingOption) -> String {
        "\(meeting.title) · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var hasResolvedSource: Bool {
        switch model.state.sourceMode {
        case .library:
            true
        case .meeting:
            selectedMeetingTitle != nil
        case .web:
            false
        }
    }
}
