import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Process-scoped presentation owner for ⌘K. Every panel generation cancels
/// the preceding search/answer tasks so a closed palette cannot republish into
/// a later invocation.
@MainActor
@Observable
final class CommandPaletteModel {
    struct PaletteAnswer: Equatable {
        let question: String
        let text: String
        let citations: [AskCitation]
    }

    struct State {
        fileprivate(set) var query = ""
        fileprivate(set) var hits: [AskSearchResult] = []
        fileprivate(set) var answer: PaletteAnswer?
        fileprivate(set) var isAnswering = false
    }

    private(set) var state = State()

    private let client: any AskModelClient
    private var searchTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var generation = 0

    init(client: any AskModelClient) {
        self.client = client
    }

    func reset() {
        generation += 1
        searchTask?.cancel()
        answerTask?.cancel()
        searchTask = nil
        answerTask = nil
        state = State()
    }

    func updateQuery(_ text: String) {
        generation += 1
        let requestGeneration = generation
        searchTask?.cancel()
        answerTask?.cancel()
        answerTask = nil
        state.query = text
        state.answer = nil
        state.isAnswering = false
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state.hits = []
            return
        }
        searchTask = Task { [weak self] in
            await self?.search(query, generation: requestGeneration)
        }
    }

    func submit() {
        let question = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !state.isAnswering else { return }
        generation += 1
        let requestGeneration = generation
        searchTask?.cancel()
        answerTask?.cancel()
        searchTask = nil
        state.isAnswering = true
        state.answer = nil
        answerTask = Task { [weak self] in
            await self?.answer(question, generation: requestGeneration)
        }
    }

    func markdownAnswer() -> String? {
        guard let answer = state.answer else { return nil }
        return AskMarkdown.format(
            question: answer.question,
            answer: answer.text,
            citations: answer.citations)
    }

    private func search(_ query: String, generation requestGeneration: Int) async {
        let hits = (try? await client.searchAskMeetings(query, limit: 6)) ?? []
        guard !Task.isCancelled, generation == requestGeneration else { return }
        state.hits = hits
        searchTask = nil
    }

    private func answer(_ question: String, generation requestGeneration: Int) async {
        let answer: PaletteAnswer
        do {
            let result = try await client.answerAskMeetings(question, limit: 6)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            let text = result.citations.isEmpty
                ? L10n.text("Nothing related in your meetings yet.")
                : result.generatedText
                    ?? L10n.text("Closest passages from your meetings:")
            answer = PaletteAnswer(
                question: question,
                text: text,
                citations: result.citations)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            answer = PaletteAnswer(
                question: question,
                text: L10n.format("Search failed: %@", error.localizedDescription),
                citations: [])
        }
        guard generation == requestGeneration else { return }
        state.answer = answer
        state.isAnswering = false
        answerTask = nil
    }
}
