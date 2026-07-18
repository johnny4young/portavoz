import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Narrow, storage-independent contract shared by the full Ask surface and
/// the process-scoped command palette.
@MainActor
protocol AskModelClient: AnyObject {
    func searchAskMeetings(
        _ query: String,
        limit: Int
    ) async throws -> [AskSearchResult]
    func answerAskMeetings(
        _ question: String,
        limit: Int
    ) async throws -> AskMeetingAnswer
}

/// Per-window presentation owner for the full Ask conversation.
@MainActor
@Observable
final class AskModel {
    struct Exchange: Identifiable, Equatable {
        let id: UUID
        let question: String
        let answer: String
        let citations: [AskCitation]

        init(
            id: UUID = UUID(),
            question: String,
            answer: String,
            citations: [AskCitation]
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.citations = citations
        }
    }

    struct State {
        fileprivate(set) var draft = ""
        fileprivate(set) var exchanges: [Exchange] = []
        fileprivate(set) var isAsking = false
    }

    private(set) var state = State()

    private let client: any AskModelClient
    private var answerTask: Task<Void, Never>?
    private var generation = 0

    init(client: any AskModelClient) {
        self.client = client
    }

    func updateDraft(_ value: String) {
        state.draft = value
    }

    func submit() {
        let question = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !state.isAsking else { return }
        state.draft = ""
        state.isAsking = true
        generation += 1
        let requestGeneration = generation
        answerTask?.cancel()
        answerTask = Task { [weak self] in
            await self?.answer(question, generation: requestGeneration)
        }
    }

    func cancelPendingAnswer() {
        generation += 1
        answerTask?.cancel()
        answerTask = nil
        state.isAsking = false
    }

    private func answer(_ question: String, generation requestGeneration: Int) async {
        let exchange: Exchange
        do {
            let result = try await client.answerAskMeetings(question, limit: 6)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            exchange = Exchange(
                question: question,
                answer: Self.presentationText(for: result),
                citations: result.citations)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            exchange = Exchange(
                question: question,
                answer: L10n.format("Search failed: %@", error.localizedDescription),
                citations: [])
        }
        guard generation == requestGeneration else { return }
        state.exchanges.append(exchange)
        state.isAsking = false
        answerTask = nil
    }

    private static func presentationText(for result: AskMeetingAnswer) -> String {
        guard !result.citations.isEmpty else {
            return L10n.text("Nothing related in your meetings yet.")
        }
        return result.generatedText
            ?? L10n.text("Closest passages from your meetings:")
    }
}
