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
    }

    private var exchangeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.state.exchanges) { exchange in
                        exchangeView(exchange)
                    }
                    if model.state.isAsking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching your meetings…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("ask-progress")
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
                ForEach(Array(exchange.citations.enumerated()), id: \.offset) { index, citation in
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
                    .accessibilityIdentifier(
                        "ask-citation-\(exchange.id.uuidString)-\(index)")
                }
            }
        }
        .id(exchange.id)
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
