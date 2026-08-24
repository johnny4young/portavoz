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
    func answerAskMeetings(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer
    func answerAskMeetings(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer
}

extension AskModelClient {
    func answerAskMeetings(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        let answer = try await answerAskMeetings(question, limit: limit)
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: answer.citations))
        return answer
    }

    func answerAskMeetings(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        let answer = try await answerAskMeetings(
            question,
            limit: limit,
            onEvidence: onEvidence)
        if let text = answer.generatedText {
            await onAnswer(AskAnswerUpdate(text: text))
        }
        return answer
    }
}

/// Per-window presentation owner for the full Ask conversation.
@MainActor
@Observable
final class AskModel {
    enum Surface: Equatable {
        case conversation
        case personCommitments
        case topicDecisions
    }

    enum PendingPhase: Equatable {
        case findingEvidence
        case refiningEvidence
        case generatingAnswer
    }

    struct Exchange: Identifiable, Equatable {
        let id: UUID
        let question: String
        let answer: String
        let citations: [AskCitation]
        let generationOutcome: AskGenerationOutcome

        init(
            id: UUID = UUID(),
            question: String,
            answer: String,
            citations: [AskCitation],
            generationOutcome: AskGenerationOutcome
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.citations = citations
            self.generationOutcome = generationOutcome
        }
    }

    struct State {
        fileprivate(set) var surface = Surface.conversation
        fileprivate(set) var draft = ""
        fileprivate(set) var exchanges: [Exchange] = []
        fileprivate(set) var isAsking = false
        fileprivate(set) var pendingQuestion: String?
        fileprivate(set) var pendingCitations: [AskCitation] = []
        fileprivate(set) var pendingAnswerText: String?
        fileprivate(set) var pendingPhase: PendingPhase?
    }

    private(set) var state = State()
    let memory: AskMemoryModel?
    let topicMemory: AskTopicMemoryModel?

    private let client: any AskModelClient
    private var answerTask: Task<Void, Never>?
    private var generation = 0

    init(
        client: any AskModelClient,
        memoryClient: (any AskMemoryModelClient)? = nil,
        memorySearchDelay: Duration = .milliseconds(200)
    ) {
        self.client = client
        memory = memoryClient.map {
            AskMemoryModel(client: $0, searchDelay: memorySearchDelay)
        }
        topicMemory = memoryClient.map {
            AskTopicMemoryModel(client: $0, searchDelay: memorySearchDelay)
        }
    }

    isolated deinit {
        answerTask?.cancel()
    }

    func selectSurface(_ surface: Surface) {
        guard surface != state.surface else { return }
        switch surface {
        case .conversation:
            memory?.cancelPendingWork()
            topicMemory?.cancelPendingWork()
        case .personCommitments:
            guard let memory else { return }
            cancelPendingAnswer()
            topicMemory?.cancelPendingWork()
            memory.activate()
        case .topicDecisions:
            guard let topicMemory else { return }
            cancelPendingAnswer()
            memory?.cancelPendingWork()
            topicMemory.activate()
        }
        state.surface = surface
    }

    func updateDraft(_ value: String) {
        state.draft = value
    }

    func submit() {
        let question = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        state.draft = ""
        generation += 1
        answerTask?.cancel()
        state.isAsking = true
        state.pendingQuestion = question
        state.pendingCitations = []
        state.pendingAnswerText = nil
        state.pendingPhase = .findingEvidence
        let requestGeneration = generation
        let client = client
        answerTask = Task { [weak self, client] in
            let exchange: Exchange
            do {
                let result = try await client.answerAskMeetings(
                    question,
                    limit: 6,
                    onEvidence: { [weak self] update in
                        await self?.publish(
                            update,
                            generation: requestGeneration)
                    },
                    onAnswer: { [weak self] update in
                        await self?.publish(
                            update,
                            generation: requestGeneration)
                    })
                guard !Task.isCancelled else { return }
                exchange = Exchange(
                    question: question,
                    answer: AskAnswerPresentation.text(for: result),
                    citations: result.citations,
                    generationOutcome: result.generationOutcome)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                exchange = Exchange(
                    question: question,
                    answer: L10n.format(
                        "Search failed: %@",
                        error.localizedDescription),
                    citations: [],
                    generationOutcome: .failed)
            }
            self?.complete(exchange, generation: requestGeneration)
        }
    }

    func cancelPendingAnswer() {
        generation += 1
        answerTask?.cancel()
        answerTask = nil
        clearPendingState()
    }

    func cancelAllWork() {
        cancelPendingAnswer()
        memory?.cancelPendingWork()
        topicMemory?.cancelPendingWork()
    }

    private func complete(
        _ exchange: Exchange,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled, generation == requestGeneration else { return }
        state.exchanges.append(exchange)
        if state.exchanges.count > 20 {
            state.exchanges.removeFirst(state.exchanges.count - 20)
        }
        clearPendingState()
        answerTask = nil
    }

    private func publish(
        _ update: AskEvidenceUpdate,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled,
              generation == requestGeneration,
              state.isAsking
        else { return }
        state.pendingCitations = update.citations
        switch update.phase {
        case .lexical:
            state.pendingPhase = update.citations.isEmpty
                ? .findingEvidence
                : .refiningEvidence
        case .fused:
            state.pendingPhase = .generatingAnswer
        }
    }

    private func publish(
        _ update: AskAnswerUpdate,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled,
              generation == requestGeneration,
              state.isAsking
        else { return }
        state.pendingAnswerText = update.text
        state.pendingPhase = .generatingAnswer
    }

    private func clearPendingState() {
        state.isAsking = false
        state.pendingQuestion = nil
        state.pendingCitations = []
        state.pendingAnswerText = nil
        state.pendingPhase = nil
    }

}
