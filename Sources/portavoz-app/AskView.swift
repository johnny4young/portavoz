import ApplicationKit
import Foundation
import SwiftUI

/// "Ask your meetings": one storage-independent presentation model renders
/// conversation state and sends questions through the shared application
/// workflow. Citations navigate to the exact meeting moment.
struct AskView: View {
    let model: AskModel
    let onOpenCitation: (AskCitation) -> Void
    let onOpenNoteCitation: (AskNoteCitation) -> Void

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
                    if model.state.isAsking {
                        pendingExchange
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

    @ViewBuilder
    private var pendingExchange: some View {
        if let question = model.state.pendingQuestion,
           let source = model.state.pendingSource,
           let phase = model.state.pendingPhase {
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
                if !model.state.pendingCitations.isEmpty {
                    Text("Evidence available now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    citationButtons(
                        model.state.pendingCitations,
                        identifierPrefix: "ask-pending-citation")
                }
                if !model.state.pendingNoteCitations.isEmpty {
                    Text("Evidence from your notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    noteCitationButtons(
                        model.state.pendingNoteCitations,
                        identifierPrefix: "ask-pending-note-citation")
                }
                if !model.state.pendingWebCitations.isEmpty {
                    Text("Web sources available now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    webCitationLinks(
                        model.state.pendingWebCitations,
                        identifierPrefix: "ask-pending-web-citation")
                }
                webFailureNotice(model.state.pendingWebSourceFailures)
                if let answerText = model.state.pendingAnswerText {
                    Text(answerText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ask-pending-answer")
                }
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
                    || !exchange.noteCitations.isEmpty
                    || !exchange.webCitations.isEmpty
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
            if !exchange.noteCitations.isEmpty {
                Text("Your note sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                noteCitationButtons(
                    exchange.noteCitations,
                    identifierPrefix:
                        "ask-note-citation-\(exchange.id.uuidString)")
            }
            if !exchange.webCitations.isEmpty {
                Text("Web sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                webCitationLinks(
                    exchange.webCitations,
                    identifierPrefix:
                        "ask-web-citation-\(exchange.id.uuidString)")
            }
            webFailureNotice(exchange.webSourceFailures)
        }
        .id(exchange.id)
    }

}

extension AskView {

    @ViewBuilder
    private func noteCitationButtons(
        _ citations: [AskNoteCitation],
        identifierPrefix: String
    ) -> some View {
        ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
            Button {
                onOpenNoteCitation(citation)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                    Text(
                        "\(L10n.text("You")) · \(citation.meetingTitle) · "
                            + AskMarkdown.clock(citation.timestamp))
                        .lineLimit(1)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PVDesign.accent)
            .help("\(citation.authoredAt.formatted())\n\(citation.text)")
            .accessibilityIdentifier("\(identifierPrefix)-\(index)")
        }
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
                questionPlaceholder,
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
                Label("Notes", systemImage: "note.text")
                    .tag(AskModel.SourceMode.notes)
                    .accessibilityIdentifier("ask-source-notes")
                Label("Web", systemImage: "globe")
                    .tag(AskModel.SourceMode.web)
                    .accessibilityIdentifier("ask-source-web")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
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
        case .notes:
            Label(
                "Only your explicit local notes will be searched. AI-enhanced notes are excluded.",
                systemImage: "person.crop.circle.badge.checkmark")
                .accessibilityIdentifier("ask-source-status-notes")
        case .web:
            webSourceStatus
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
        case .notes:
            Label("Source: Notes", systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier)-notes")
        case .web(let host):
            Label("Source: \(host)", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier)-web")
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
        case .notes:
            true
        case .web:
            model.state.webConsentApproved && model.canApproveWebConsent
        }
    }

}
