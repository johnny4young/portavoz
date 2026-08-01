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
            if model.state.exchanges.isEmpty && !model.state.isAsking {
                ContentUnavailableView(
                    "Ask your meetings",
                    systemImage: "bubble.left.and.text.bubble.right",
                    // One-line UI copy.
                    // swiftlint:disable:next line_length
                    description: Text("Questions like \"what did we agree about the budget?\" — answered on your Mac, citing meeting and moment.")
                )
            } else {
                exchangeList
            }
            inputBar
        }
        .navigationTitle("Ask your meetings")
        .onAppear { questionFocused = true }
        .onDisappear { model.cancelPendingAnswer() }
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
                       let phase = model.state.pendingPhase {
                        pendingExchange(
                            question: question,
                            citations: model.state.pendingCitations,
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
        citations: [AskCitation],
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
        }
    }

    private func exchangeView(_ exchange: AskModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.callout.weight(.semibold))
                .padding(10)
                .background(PVDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(exchange.answer)
                .textSelection(.enabled)
                .accessibilityIdentifier("ask-answer-\(exchange.id.uuidString)")
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
                model.state.isAsking
                    || model.state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("ask-submit")
        }
        .padding(12)
    }
}
