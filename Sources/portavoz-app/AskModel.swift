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
    private var followUpTask: Task<Void, Never>?
    private var evidenceTasks: [UUID: Task<Void, Never>] = [:]
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
        followUpTask?.cancel()
        evidenceTasks.values.forEach { $0.cancel() }
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
        if state.sourceMode == .notes {
            submitNotes(question)
            return
        }
        guard let source = resolvedSource(),
              let exchangeSource = exchangeSource(for: source)
        else { return }
        let requestGeneration = beginRequest(
            question: question,
            source: exchangeSource)
        let client = client
        let asked = ContinuousClock.now
        answerTask = Task { [weak self, client] in
            let exchange: Exchange
            var generatedText: String?
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
                exchange = Self.exchange(
                    question: question,
                    result: result,
                    source: exchangeSource,
                    answeredIn: ContinuousClock.now - asked)
                generatedText = result.generatedText
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
            guard let self, self.complete(exchange, generation: requestGeneration)
            else { return }
            self.enrich(exchange, answer: generatedText)
        }
    }

    /// Asks a suggested follow-up from the same source as the answer that offered it.
    func askFollowUp(_ suggestion: String) {
        switch state.exchanges.last(where: { $0.followUps.contains(suggestion) })?.source {
        case .library:
            selectSourceMode(.library)
        case .meeting(let id, _):
            selectSourceMode(.meeting)
            selectSourceMeeting(id)
        case .notes, .web, nil:
            break
        }
        updateDraft(suggestion)
        submit()
    }

    func cancelPendingAnswer() {
        generation += 1
        answerTask?.cancel()
        answerTask = nil
        clearPendingState()
    }

    func cancelAllWork() {
        cancelPendingAnswer()
        cancelFollowUps()
        evidenceTasks.values.forEach { $0.cancel() }
        evidenceTasks = [:]
        sourceLoadGeneration += 1
        sourceLoadTask?.cancel()
        sourceLoadTask = nil
        if state.sourceCatalogState == .loading {
            state.sourceCatalogState = .idle
        }
        memory?.cancelPendingWork()
        topicMemory?.cancelPendingWork()
    }

    @discardableResult
    private func complete(
        _ exchange: Exchange,
        generation requestGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled, generation == requestGeneration else { return false }
        state.exchanges.append(exchange)
        if state.exchanges.count > 20 {
            state.exchanges.removeFirst(state.exchanges.count - 20)
        }
        clearPendingState()
        answerTask = nil
        return true
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
        _ update: AskNoteEvidenceUpdate,
        generation requestGeneration: Int
    ) {
        guard !Task.isCancelled,
              generation == requestGeneration,
              state.isAsking
        else { return }
        state.pendingNoteCitations = update.citations
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
        state.pendingNoteCitations = []
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
        case .notes:
            .notes
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
        case .notes:
            .notes
        case .web:
            resolvedWebSourceURL()?.host.map { .web(host: $0) }
        }
    }

}

extension AskModel {

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

    private func submitNotes(_ question: String) {
        let requestGeneration = beginRequest(
            question: question,
            source: .notes)
        let client = client
        answerTask = Task { [weak self, client] in
            let exchange: Exchange
            do {
                let result = try await client.answerAskNotes(
                    question,
                    limit: 6,
                    onEvidence: { [weak self] update in
                        await self?.publish(
                            update,
                            generation: requestGeneration)
                    })
                guard !Task.isCancelled else { return }
                exchange = Exchange(
                    question: question,
                    answer: AskAnswerPresentation.text(for: result),
                    citations: [],
                    noteCitations: result.citations,
                    generationOutcome: result.generationOutcome,
                    source: .notes)
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
                    source: .notes)
            }
            self?.complete(exchange, generation: requestGeneration)
        }
    }

    /// Only the latest generated meeting answer gets suggestions, so a stale
    /// generation never holds the local model while the next question waits.
    private func suggestFollowUps(after exchange: Exchange) {
        guard exchange.generationOutcome == .generated,
              !exchange.citations.isEmpty
        else { return }
        let client = client
        followUpTask = Task { [weak self, client] in
            let suggestions = (try? await client.suggestAskFollowUps(
                question: exchange.question,
                answer: exchange.answer,
                citations: exchange.citations)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.followUpTask = nil
            guard let index = self.state.exchanges.firstIndex(where: { $0.id == exchange.id })
            else { return }
            self.state.exchanges[index].followUps = suggestions
        }
    }

    private func cancelFollowUps() {
        followUpTask?.cancel()
        followUpTask = nil
    }

    private func enrich(_ exchange: Exchange, answer: String?) {
        loadEvidence(for: exchange, answer: answer)
        suggestFollowUps(after: exchange)
    }

    /// Evidence rows are best effort and never hold the answer back: the
    /// citations show until the rows arrive, and stay if the read fails.
    private func loadEvidence(for exchange: Exchange, answer: String?) {
        guard !exchange.citations.isEmpty else { return }
        let client = client
        evidenceTasks[exchange.id] = Task { [weak self, client] in
            let evidence = try? await client.loadAskEvidence(exchange.citations, answer: answer)
            guard !Task.isCancelled, let self else { return }
            self.evidenceTasks[exchange.id] = nil
            guard let evidence,
                  let index = self.state.exchanges.firstIndex(where: { $0.id == exchange.id })
            else { return }
            self.state.exchanges[index].evidence = evidence
        }
    }

    private static func exchange(
        question: String,
        result: AskMeetingAnswer,
        source: ExchangeSource,
        answeredIn: Duration
    ) -> Exchange {
        Exchange(
            question: question,
            answer: AskAnswerPresentation.text(for: result),
            citations: result.citations,
            generationOutcome: result.generationOutcome,
            source: source,
            answeredIn: answeredIn)
    }

    private func beginRequest(
        question: String,
        source: ExchangeSource
    ) -> Int {
        state.draft = ""
        generation += 1
        answerTask?.cancel()
        cancelFollowUps()
        state.isAsking = true
        state.pendingQuestion = question
        state.pendingCitations = []
        state.pendingNoteCitations = []
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
