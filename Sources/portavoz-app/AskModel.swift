import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// Per-window presentation owner for the full Ask conversation.
@MainActor
@Observable
final class AskModel {
    private static let sourceMeetingLimit = 20

    private(set) var state = State()
    let memory: AskMemoryModel?
    let topicMemory: AskTopicMemoryModel?

    private let client: any AskModelClient
    private let webSourcePolicy: AskWebURLPolicy
    private var answerTask: Task<Void, Never>?
    private var sourceLoadTask: Task<Void, Never>?
    private var generation = 0
    private var sourceLoadGeneration = 0

    init(
        client: any AskModelClient,
        memoryClient: (any AskMemoryModelClient)? = nil,
        memorySearchDelay: Duration = .milliseconds(200),
        webSourcePolicy: AskWebURLPolicy = .publicHTTPS
    ) {
        self.client = client
        self.webSourcePolicy = webSourcePolicy
        memory = memoryClient.map {
            AskMemoryModel(client: $0, searchDelay: memorySearchDelay)
        }
        topicMemory = memoryClient.map {
            AskTopicMemoryModel(client: $0, searchDelay: memorySearchDelay)
        }
    }

    isolated deinit {
        answerTask?.cancel()
        sourceLoadTask?.cancel()
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
        if value != state.draft {
            state.webConsentApproved = false
        }
        state.draft = value
    }

    func updateWebSourceDraft(_ value: String) {
        if value != state.webSourceDraft {
            state.webConsentApproved = false
            if case .web = state.pendingSource {
                cancelPendingAnswer()
            }
        }
        state.webSourceDraft = value
    }

    func setWebConsentApproved(_ isApproved: Bool) {
        state.webConsentApproved = isApproved
            && resolvedWebSourceURL() != nil
            && !state.draft.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
    }

    var canApproveWebConsent: Bool {
        resolvedWebSourceURL() != nil
            && !state.draft.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
    }

    func selectSourceMode(_ mode: SourceMode) {
        guard mode != state.sourceMode else { return }
        cancelPendingAnswer()
        state.sourceMode = mode
        if mode == .meeting {
            loadSourceMeetingsIfNeeded()
        }
    }

    func selectSourceMeeting(_ meetingID: MeetingID) {
        guard state.sourceMeetings.contains(where: { $0.id == meetingID }),
              meetingID != state.selectedSourceMeetingID
        else { return }
        cancelPendingAnswer()
        state.selectedSourceMeetingID = meetingID
    }

    func loadSourceMeetingsIfNeeded() {
        guard state.sourceCatalogState == .idle else { return }
        loadSourceMeetings()
    }

    func retrySourceMeetings() {
        guard state.sourceCatalogState == .failed else { return }
        loadSourceMeetings()
    }

    func submit() {
        let question = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if state.sourceMode == .web {
            submitWeb(question)
            return
        }
        guard let source = resolvedSource(),
              let exchangeSource = exchangeSource(for: source)
        else { return }
        let requestGeneration = beginRequest(
            question: question,
            source: exchangeSource)
        let client = client
        answerTask = Task { [weak self, client] in
            let exchange: Exchange
            do {
                let result = try await client.answerAskMeetings(
                    question,
                    source: source,
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
                    generationOutcome: result.generationOutcome,
                    source: exchangeSource)
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
                    generationOutcome: .failed,
                    source: exchangeSource)
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
        sourceLoadGeneration += 1
        sourceLoadTask?.cancel()
        sourceLoadTask = nil
        if state.sourceCatalogState == .loading {
            state.sourceCatalogState = .idle
        }
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
        _ update: AskWebEvidenceUpdate,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled,
              generation == requestGeneration,
              state.isAsking
        else { return }
        state.pendingWebCitations = update.citations
        state.pendingWebSourceFailures = update.sourceFailures
        state.pendingPhase = update.citations.isEmpty
            ? .findingEvidence
            : .generatingAnswer
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
        state.pendingWebCitations = []
        state.pendingWebSourceFailures = []
        state.pendingAnswerText = nil
        state.pendingPhase = nil
        state.pendingSource = nil
    }

    private func loadSourceMeetings() {
        sourceLoadGeneration += 1
        let requestGeneration = sourceLoadGeneration
        sourceLoadTask?.cancel()
        state.sourceCatalogState = .loading
        let client = client
        sourceLoadTask = Task { [weak self, client] in
            do {
                let meetings = try await client.loadAskSourceMeetings(
                    limit: Self.sourceMeetingLimit)
                guard Self.isValidSourceMeetingCatalog(meetings) else {
                    throw AskSourceMeetingCatalogError.invalidResponse
                }
                guard !Task.isCancelled,
                      self?.sourceLoadGeneration == requestGeneration
                else { return }
                self?.state.sourceMeetings = meetings
                if let selected = self?.state.selectedSourceMeetingID,
                   !meetings.contains(where: { $0.id == selected }) {
                    self?.state.selectedSourceMeetingID = nil
                }
                self?.state.sourceCatalogState = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self?.sourceLoadGeneration == requestGeneration
                else { return }
                self?.state.sourceMeetings = []
                self?.state.selectedSourceMeetingID = nil
                self?.state.sourceCatalogState = .failed
            }
            self?.sourceLoadTask = nil
        }
    }

    private func resolvedSource() -> AskSourceScope? {
        switch state.sourceMode {
        case .library:
            .library
        case .meeting:
            state.selectedSourceMeetingID.map(AskSourceScope.meeting)
        case .web:
            .web
        }
    }

    private func exchangeSource(
        for source: AskSourceScope
    ) -> ExchangeSource? {
        switch source {
        case .library:
            .library
        case .meeting(let meetingID):
            state.sourceMeetings.first(where: { $0.id == meetingID }).map {
                .meeting(id: $0.id, title: $0.title)
            }
        case .web:
            resolvedWebSourceURL()?.host.map { .web(host: $0) }
        }
    }

    private func submitWeb(_ question: String) {
        guard state.webConsentApproved,
              let url = resolvedWebSourceURL(),
              let host = url.host
        else { return }
        state.webConsentApproved = false
        let requestGeneration = beginRequest(
            question: question,
            source: .web(host: host))
        let request = AskWebRequest(
            question: question,
            sourceURLs: [url],
            consent: .approvedForSingleRequest)
        let client = client
        answerTask = Task { [weak self, client] in
            let exchange: Exchange
            do {
                let result = try await client.answerAskWeb(
                    request,
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
                    citations: [],
                    webCitations: result.citations,
                    webSourceFailures: result.sourceFailures,
                    generationOutcome: result.generationOutcome,
                    source: .web(host: host))
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
                    generationOutcome: .failed,
                    source: .web(host: host))
            }
            self?.complete(exchange, generation: requestGeneration)
        }
    }

    private func beginRequest(
        question: String,
        source: ExchangeSource
    ) -> Int {
        state.draft = ""
        generation += 1
        answerTask?.cancel()
        state.isAsking = true
        state.pendingQuestion = question
        state.pendingCitations = []
        state.pendingWebCitations = []
        state.pendingWebSourceFailures = []
        state.pendingAnswerText = nil
        state.pendingPhase = .findingEvidence
        state.pendingSource = source
        return generation
    }

    private func resolvedWebSourceURL() -> URL? {
        let value = state.webSourceDraft.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let host = url.host,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              !host.isEmpty
        else { return nil }
        guard AskWebURLValidator.admits(url, policy: webSourcePolicy) else {
            return nil
        }
        return url
    }

    private static func isValidSourceMeetingCatalog(
        _ meetings: [AskSourceMeetingOption]
    ) -> Bool {
        guard meetings.count <= sourceMeetingLimit else { return false }
        var identities = Set<MeetingID>()
        return meetings.allSatisfy { meeting in
            identities.insert(meeting.id).inserted
                && meeting.title.contains { !$0.isWhitespace }
        }
    }

}

private enum AskSourceMeetingCatalogError: Error {
    case invalidResponse
}
