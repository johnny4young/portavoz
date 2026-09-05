import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

enum AppAskAnswerProviderResolution: Sendable {
    case available(any RAGTextAnswering)
    case unavailable(SummaryRegenerationUnavailability)
}

/// Late-bound bridge from the application use case to the engine preference
/// sampled for each explicit Ask. The resolver is installed only after
/// `AppServices` is fully initialized; no composition closure captures a
/// partially initialized service graph.
final class AppSelectedAskMeetingAnswering:
    AskMeetingAnswering,
    AskNoteAnswering,
    AskWebAnswering,
    InterviewQuestionAnswering,
    @unchecked Sendable {
    typealias Resolver = @MainActor @Sendable () async
        -> AppAskAnswerProviderResolution

    private let lock = NSLock()
    private var resolver: Resolver?

    @discardableResult
    func install(_ resolver: @escaping Resolver) -> Bool {
        lock.withLock {
            guard self.resolver == nil else { return false }
            self.resolver = resolver
            return true
        }
    }

    func answer(
        question: String,
        citations: [AskCitation]
    ) async throws -> String? {
        try await answer(
            question: question,
            citations: citations,
            onAnswer: { _ in })
    }

    func answer(
        question: String,
        citations: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        guard let resolver = currentResolver() else { return nil }
        switch await resolver() {
        case .unavailable:
            return nil
        case .available(let provider):
            return try await provider.streamAnswer(
                question: question,
                passages: citations.map(Self.passage),
                onSnapshot: { text in
                    await onAnswer(AskAnswerUpdate(text: text))
                })
        }
    }

    private func currentResolver() -> Resolver? {
        lock.withLock { resolver }
    }

    private static func passage(_ citation: AskCitation) -> RAGPassage {
        RAGPassage(
            segmentID: citation.segmentID,
            sourceSegmentIDs: citation.sourceSegmentIDs,
            meetingID: citation.meetingID,
            meetingTitle: citation.meetingTitle,
            timestamp: citation.timestamp,
            transcriptRevision: citation.transcriptRevision,
            text: citation.text)
    }

    func answer(
        question: String,
        citations: [AskNoteCitation]
    ) async throws -> String? {
        guard let resolver = currentResolver() else { return nil }
        switch await resolver() {
        case .unavailable:
            return nil
        case .available(let provider):
            return try await provider.answer(
                question: question,
                notePassages: citations.map(Self.notePassage))
        }
    }

    private static func notePassage(
        _ citation: AskNoteCitation
    ) -> RAGNotePassage {
        RAGNotePassage(
            noteID: citation.noteID,
            meetingID: citation.meetingID,
            meetingTitle: citation.meetingTitle,
            author: citation.author.rawValue,
            authoredAt: citation.authoredAt,
            timestamp: citation.timestamp,
            text: citation.text)
    }

    func answer(
        question: String,
        citations: [AskWebCitation]
    ) async throws -> String? {
        try await answer(
            question: question,
            citations: citations,
            onAnswer: { _ in })
    }

    func answer(
        question: String,
        citations: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        guard let resolver = currentResolver() else { return nil }
        switch await resolver() {
        case .unavailable:
            return nil
        case .available(let provider):
            return try await provider.streamAnswer(
                question: question,
                webPassages: citations.map(Self.webPassage),
                onSnapshot: { text in
                    await onAnswer(AskAnswerUpdate(text: text))
                })
        }
    }

    private static func webPassage(_ citation: AskWebCitation) -> RAGWebPassage {
        RAGWebPassage(
            url: citation.url,
            title: citation.title,
            observedDate: citation.observedDate,
            text: citation.text,
            isExcerptTruncated: citation.isExcerptTruncated)
    }

    func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String? {
        guard let resolver = currentResolver() else { return nil }
        switch await resolver() {
        case .unavailable:
            return nil
        case .available(let provider):
            // The provider may stream internally, but interview presentation
            // waits for the complete citation-valid answer before exposing
            // model prose as a supported claim.
            return try await provider.streamAnswer(
                question: question,
                passages: passages,
                onSnapshot: { _ in })
        }
    }
}

extension AppServices {
    /// Installs only after every stored service is initialized. The retained
    /// resolver remains weak to avoid a composition-root cycle; a request
    /// holds the resolved service strongly only for its own async selection.
    func installSelectedAskResolver(
        on selectedAskAnswering: AppSelectedAskMeetingAnswering
    ) {
        selectedAskAnswering.install { @MainActor [weak self] in
            guard let self else {
                return .unavailable(.appleOnDevice(
                    reason: "Application services are unavailable"))
            }
            return await self.summaryProviderResolver.resolveAsk(
                mlxProvider: { directory, priority in
                    self.makeMLXRAGAnswerer(
                        modelDirectory: directory,
                        priority: priority)
                })
        }
    }
}
