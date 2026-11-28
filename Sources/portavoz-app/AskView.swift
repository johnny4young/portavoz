import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

private extension View {
    /// One centred reading column for the answers and the composer under them.
    func askColumn() -> some View {
        padding(.horizontal, PVDesign.space6 * 2)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// "Ask your meetings": one storage-independent presentation model renders
/// conversation state and sends questions through the shared application
/// workflow. Citations navigate to the exact meeting moment.
struct AskView: View {
    /// Below this column width a "Who said it" row stacks its strip under the
    /// quote, so a quote never wraps at two or three words a line.
    private static let compactRowsWidth: CGFloat = 640

    let model: AskModel
    let onOpenCitation: (AskCitation) -> Void
    let onOpenNoteCitation: (AskNoteCitation) -> Void
    let onOpenCommitments: ([CommitmentID]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var questionFocused: Bool
    @State private var compactRows = false
    @State private var copiedExchange: UUID?

    var body: some View {
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The window keeps its title for the Window menu; the toolbar draws it.
        .navigationTitle("Ask")
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .onAppear {
            questionFocused = model.state.surface == .conversation
            model.resumeEvidence()
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarTitle("Ask")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .automatic) {
            if model.memory != nil || model.topicMemory != nil {
                surfacePicker
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Answers read as a page; the composer and its follow-ups stay at the foot.
    private var conversation: some View {
        VStack(spacing: 0) {
            if model.state.exchanges.isEmpty && !model.state.isAsking {
                ContentUnavailableView(
                    "Ask your meetings",
                    systemImage: PVSymbol.ask,
                    // One-line UI copy.
                    // swiftlint:disable:next line_length
                    description: Text("Questions like \"what did we agree about the budget?\" — answered on your Mac, citing meeting and moment."))
                    .frame(maxHeight: .infinity)
            } else {
                exchangeList
            }
            composerArea
                .padding(.top, PVDesign.space3)
                .padding(.bottom, 18)
                .askColumn()
        }
    }

    private var surfacePicker: some View {
        PVSegmentedControl(
            segments: [
                PVSegment(
                    value: AskModel.Surface.conversation, title: L10n.text("Ask"),
                    accessibilityIdentifier: "ask-surface-conversation"),
                PVSegment(
                    value: AskModel.Surface.personCommitments, title: L10n.text("By person"),
                    accessibilityIdentifier: "ask-surface-person-commitments"),
                PVSegment(
                    value: AskModel.Surface.topicDecisions, title: L10n.text("By topic"),
                    accessibilityIdentifier: "ask-surface-topic-decisions")
            ],
            selection: Binding(
                get: { model.state.surface },
                set: { model.selectSurface($0) }))
        .fixedSize()
        .padding(.trailing, HomeToolbarLayout.trailingInset)
        .accessibilityLabel(L10n.text("Ask view"))
        .accessibilityIdentifier("ask-surface")
    }

    private var exchangeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    ForEach(model.state.exchanges) { exchange in
                        exchangeView(exchange)
                    }
                    if model.state.isAsking {
                        pendingExchange
                            .id("asking")
                    }
                }
                .onGeometryChange(for: Bool.self) { [threshold = Self.compactRowsWidth] in
                    $0.size.width < threshold
                } action: { compactRows = $0 }
                .padding(.top, 14)
                .padding(.bottom, PVDesign.space6)
                .askColumn()
            }
            .accessibilityIdentifier("ask-exchange-scroll")
            .onChange(of: model.state.exchanges.count) { _, _ in
                if let last = model.state.exchanges.last?.id {
                    proxy.pvScrollTo(last, anchor: .top, reduceMotion: reduceMotion)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingExchange: some View {
        if let question = model.state.pendingQuestion,
           let askedAt = model.state.pendingAskedAt,
           let source = model.state.pendingSource,
           let phase = model.state.pendingPhase {
            VStack(alignment: .leading, spacing: 12) {
                AskQuestionHeader(
                    question: question, askedAt: askedAt, answeredIn: nil,
                    identifier: "ask-pending-question") {
                    sourceBadge(source, identifier: "ask-pending-source")
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressText(for: phase))
                        .foregroundStyle(.ink3)
                        .accessibilityIdentifier(progressIdentifier(for: phase))
                    Spacer()
                    Button("Cancel") {
                        model.cancelPendingAnswer()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("ask-cancel")
                }
                if let answerText = model.state.pendingAnswerText {
                    Text(verbatim: answerText)
                        .askAnswerText()
                        .accessibilityIdentifier("ask-pending-answer")
                        .askAnswerSurface()
                }
                if !model.state.pendingCitations.isEmpty {
                    Text("Sources found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ink3)
                    FlowLayout(spacing: 10, rowSpacing: 4) {
                        citationButtons(
                            model.state.pendingCitations,
                            identifierPrefix: "ask-pending-citation")
                    }
                }
                if !model.state.pendingNoteCitations.isEmpty {
                    Text("From your notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ink3)
                    noteCitationButtons(
                        model.state.pendingNoteCitations,
                        identifierPrefix: "ask-pending-note-citation")
                }
                if !model.state.pendingWebCitations.isEmpty {
                    Text("Web sources available now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ink3)
                    webCitationLinks(
                        model.state.pendingWebCitations,
                        identifierPrefix: "ask-pending-web-citation")
                }
                webFailureNotice(model.state.pendingWebSourceFailures)
            }
        }
    }

    private func exchangeView(_ exchange: AskModel.Exchange) -> some View {
        let id = exchange.id.uuidString
        return VStack(alignment: .leading, spacing: 0) {
            AskQuestionHeader(
                question: exchange.question, askedAt: exchange.askedAt, answeredIn: exchange.answeredIn,
                identifier: "ask-question-\(id)") {
                sourceBadge(exchange.source, identifier: "ask-exchange-source")
            }
            AskAnswerCard(
                pieces: exchange.answerPieces,
                generatedFrom: generatedFrom(exchange),
                openCommitments: exchange.evidence?.openCommitments ?? [],
                copied: copiedExchange == exchange.id,
                identifier: id,
                onCopy: { copy(exchange) },
                onOpenCommitments: onOpenCommitments,
                status: AskAnswerPresentation.statusText(
                    for: exchange.generationOutcome, hasCitations: exchange.hasCitations
                ).map { ($0, "ask-generation-\(exchange.generationOutcome.rawValue)") })
            .padding(.top, 18)
            if !exchange.rows.isEmpty {
                AskWhoSaidIt(
                    rows: exchange.rows, compact: compactRows, identifier: "ask-evidence-\(id)",
                    onPlay: onOpenCitation)
                    .padding(.top, 22)
            }
            if !exchange.noteCitations.isEmpty || !exchange.webCitations.isEmpty {
                // Notes and web pages keep their own marks; only meeting moments have a voice.
                FlowLayout(spacing: 10, rowSpacing: 4) {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ink3)
                    noteCitationButtons(
                        exchange.noteCitations,
                        identifierPrefix: "ask-note-citation-\(id)")
                    webCitationLinks(
                        exchange.webCitations,
                        identifierPrefix: "ask-web-citation-\(id)")
                }
                .padding(.top, 14)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ask-sources-\(id)")
            }
            webFailureNotice(exchange.webSourceFailures)
                .padding(.top, 8)
        }
        .id(exchange.id)
    }

    private func generatedFrom(_ exchange: AskModel.Exchange) -> String? {
        guard exchange.generationOutcome == .generated, !exchange.citations.isEmpty else { return nil }
        return AskEvidencePresentation.generatedFrom(
            voices: exchange.evidence?.voiceCount ?? 0,
            meetings: Set(exchange.citations.map(\.meetingID)).count)
    }

    private func copy(_ exchange: AskModel.Exchange) {
        let markdown = AskEvidencePresentation.markdown(
            question: exchange.question, answer: exchange.answer, rows: exchange.rows)
        guard PasteboardCopy.copy(markdown) else { return }
        copiedExchange = exchange.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedExchange == exchange.id { copiedExchange = nil }
        }
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
                    Text(PVFont.timeCoded(
                        "\(L10n.text("You")) · \(citation.meetingTitle)",
                        at: AskMarkdown.clock(citation.timestamp)))
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
                    Text(PVFont.timeCoded(citation.meetingTitle, at: AskMarkdown.clock(citation.timestamp)))
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
            "Finding exact matches…"
        case .refiningEvidence:
            "Exact matches found, checking related ones…"
        case .generatingAnswer:
            "Sources ready, writing the answer…"
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

    /// Follow-ups, then whatever the chosen source still needs, then the field.
    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            followUps
            sourcePolicyStatus
                .font(.caption)
                .foregroundStyle(PVDesign.ink3)
            composer
        }
    }

    @ViewBuilder private var followUps: some View {
        if !model.state.isAsking, let suggestions = model.state.exchanges.last?.followUps, !suggestions.isEmpty {
            FlowLayout(spacing: 8, rowSpacing: 6) {
                PVCardCaption(text: L10n.text("Follow up"), tint: PVDesign.ink3)
                    .frame(height: 26)
                    .padding(.trailing, 4)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    Button {
                        model.askFollowUp(suggestion)
                    } label: {
                        Text(verbatim: suggestion)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PVDesign.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(PVDesign.line, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ask-follow-up-\(index)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask-follow-ups")
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                questionPlaceholder,
                text: Binding(
                    get: { model.state.draft },
                    set: { model.updateDraft($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($questionFocused)
                .onSubmit { model.submit() }
                .accessibilityIdentifier("ask-question-field")
            HStack(spacing: 5) {
                sourceChip(.library, title: "Library", id: "ask-source-library")
                sourceChip(.meeting, title: "Meeting", id: "ask-source-meeting")
                sourceChip(.notes, title: "Notes", id: "ask-source-notes")
                sourceChip(.web, title: "Web", id: "ask-source-web")
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("Answer sources"))
            .accessibilityIdentifier("ask-source-picker")
            Button {
                model.submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PVDesign.onInk)
                    .frame(width: 30, height: 30)
                    .background(PVDesign.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.35)
            .accessibilityLabel(L10n.text("Send question"))
            .accessibilityIdentifier("ask-submit")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 46)
        .background {
            PVRaisedSurface(cornerRadius: PVDesign.radiusPanel)
                .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
        }
    }

    private var canSubmit: Bool {
        !model.state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasResolvedSource
    }

    private func sourceChip(
        _ mode: AskModel.SourceMode,
        title: LocalizedStringKey,
        id: String
    ) -> some View {
        let selected = model.state.sourceMode == mode
        return Button {
            model.selectSourceMode(mode)
        } label: {
            Text(title)
                .foregroundStyle(selected ? PVDesign.onInk : PVDesign.ink2)
                .pvPill(selected ? PVDesign.ink : PVDesign.line)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var sourcePolicyStatus: some View {
        switch model.state.sourceMode {
        case .library:
            // After the first Library answer its receipt says the same.
            if !model.state.exchanges.contains(where: { $0.source == .library && $0.answeredIn != nil }) {
                Label(
                    "Only your local meeting library will be searched.",
                    systemImage: "lock")
                    .accessibilityIdentifier("ask-source-status-library")
            }
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
                Label("Meeting list unavailable.", systemImage: PVSymbol.warning)
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
            // The Library is the default source; only a narrower one is named.
            EmptyView()
        case .meeting(_, let title):
            Label("Source: \(title)", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.ink3)
                .accessibilityIdentifier("\(identifier)-meeting")
        case .notes:
            Label("Source: Notes", systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.ink3)
                .accessibilityIdentifier("\(identifier)-notes")
        case .web(let host):
            Label("Source: \(host)", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.ink3)
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
