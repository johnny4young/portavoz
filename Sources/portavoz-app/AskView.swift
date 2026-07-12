import IntegrationsKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// "Ask your meetings" (M8's local RAG, surfaced in the UI): natural-language
/// questions answered on-device, citing meeting + moment. Citations navigate
/// straight to the meeting. Nothing leaves the Mac.
struct AskView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?

    @State private var question = ""
    @State private var exchanges: [AskExchange] = []
    @State private var asking = false
    @FocusState private var questionFocused: Bool

    struct AskExchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
        let passages: [RAGPassage]
    }

    var body: some View {
        VStack(spacing: 0) {
            if exchanges.isEmpty && !asking {
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
                    ForEach(exchanges) { exchange in
                        exchangeView(exchange)
                    }
                    if asking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching your meetings…").foregroundStyle(.secondary)
                        }
                        .id("asking")
                    }
                }
                .padding(16)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .onChange(of: exchanges.count) { _, _ in
                if let last = exchanges.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func exchangeView(_ exchange: AskExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.callout.weight(.semibold))
                .padding(10)
                .background(PVDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(exchange.answer)
                .textSelection(.enabled)
            if !exchange.passages.isEmpty {
                Text("Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(exchange.passages.enumerated()), id: \.offset) { _, passage in
                    Button {
                        route = .meeting(passage.meetingID)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                            Text("\(passage.meetingTitle) · \(clock(passage.timestamp))")
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PVDesign.accent)
                    .help(passage.text)
                }
            }
        }
        .id(exchange.id)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your meetings…", text: $question)
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .onSubmit(ask)
            Button(action: ask) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        question = ""
        asking = true
        Task {
            defer { asking = false }
            do {
                let passages = try await AskPipeline.retrieve(
                    question: text, store: services.store)
                guard !passages.isEmpty else {
                    exchanges.append(AskExchange(
                        question: text,
                        answer: L10n.text("Nothing related in your meetings yet."),
                        passages: []))
                    return
                }
                var answer: String?
                if #available(macOS 26.0, *),
                    FoundationModelSummaryProvider.unavailabilityReason() == nil {
                    answer = try? await RAGAnswerer().answer(question: text, passages: passages)
                }
                exchanges.append(AskExchange(
                    question: text,
                    answer: answer ?? L10n.text("Closest passages from your meetings:"),
                    passages: passages))
            } catch {
                exchanges.append(AskExchange(
                    question: text,
                    answer: L10n.format("Search failed: %@", error.localizedDescription),
                    passages: []))
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
