import Foundation
import PortavozCore

/// Explicit one-request authority. The UI consumes this approval when a Web
/// question starts; changing the question requires a new value.
public enum AskWebConsent: Equatable, Sendable {
    case approvedForSingleRequest
}

public enum AskWebRequestError: Error, Equatable, LocalizedError, Sendable {
    case emptyQuestion
    case noSources
    case tooManySources
    case duplicateSource

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            "Ask a question before searching the web."
        case .noSources:
            "Add a web source before asking."
        case .tooManySources:
            "Too many web sources were selected."
        case .duplicateSource:
            "Each web source must be unique."
        }
    }
}

public struct AskWebRequest: Equatable, Sendable {
    public let question: String
    public let sourceURLs: [URL]
    public let consent: AskWebConsent

    public init(
        question: String,
        sourceURLs: [URL],
        consent: AskWebConsent
    ) {
        self.question = question
        self.sourceURLs = sourceURLs
        self.consent = consent
    }
}

public struct AskWebAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let citations: [AskWebCitation]
    public let sourceFailures: [AskWebSourceFailure]
    public let generationOutcome: AskGenerationOutcome

    public init(
        question: String,
        generatedText: String?,
        citations: [AskWebCitation],
        sourceFailures: [AskWebSourceFailure],
        generationOutcome: AskGenerationOutcome
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
        self.sourceFailures = sourceFailures
        self.generationOutcome = generationOutcome
    }
}

public struct AskWebEvidenceUpdate: Equatable, Sendable {
    public let citations: [AskWebCitation]
    public let sourceFailures: [AskWebSourceFailure]

    public init(
        citations: [AskWebCitation],
        sourceFailures: [AskWebSourceFailure]
    ) {
        self.citations = citations
        self.sourceFailures = sourceFailures
    }
}

public typealias AskWebEvidenceReceiver =
    @Sendable (AskWebEvidenceUpdate) async -> Void

public protocol AskWebAnswering: Sendable {
    func answer(
        question: String,
        citations: [AskWebCitation]
    ) async throws -> String?
    func answer(
        question: String,
        citations: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String?
}

public extension AskWebAnswering {
    func answer(
        question: String,
        citations: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        let text = try await answer(question: question, citations: citations)
        if let text {
            await onAnswer(AskAnswerUpdate(text: text))
        }
        return text
    }
}

/// One bounded direct-source Web Ask. URLs are supplied explicitly rather
/// than discovered by a scraper or search provider; the question and every
/// local meeting stay out of the page request.
public struct AskWeb: Sendable {
    public static let maximumSources = 3

    private let retrieval: any AskWebSourceRetrieving
    private let answering: any AskWebAnswering
    private let answerTimeout: Duration

    public init(
        retrieval: any AskWebSourceRetrieving,
        answering: any AskWebAnswering,
        answerTimeout: Duration = .seconds(8)
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.answerTimeout = answerTimeout > .zero
            ? answerTimeout
            : .seconds(8)
    }

    public func answer(
        _ request: AskWebRequest,
        onEvidence: @escaping AskWebEvidenceReceiver = { _ in },
        onAnswer: @escaping AskAnswerReceiver = { _ in }
    ) async throws -> AskWebAnswer {
        let question = try Self.validate(request)
        let evidence = try await retrieve(request.sourceURLs)
        try Task.checkCancellation()
        await onEvidence(evidence)
        try Task.checkCancellation()
        guard !evidence.citations.isEmpty else {
            return AskWebAnswer(
                question: question,
                generatedText: nil,
                citations: [],
                sourceFailures: evidence.sourceFailures,
                generationOutcome: .notRequested)
        }

        let gate = AskWebAnswerUpdateGate(
            citationCount: evidence.citations.count)
        let generation: AskGenerationResult
        do {
            let text = try await withAskTimeout(
                answerTimeout,
                onTimeout: { await gate.close() },
                operation: { [answering] in
                    try await answering.answer(
                        question: question,
                        citations: evidence.citations,
                        onAnswer: { update in
                            if let admitted = await gate.admit(update) {
                                await onAnswer(admitted)
                            }
                        })
                })
            let final = await gate.finalize(text)
            if let update = final.update {
                await onAnswer(update)
            }
            generation = AskGenerationResult(
                text: final.text,
                outcome: final.text == nil ? .failed : .generated)
        } catch is CancellationError {
            await gate.close()
            throw CancellationError()
        } catch is AskTimeoutError {
            generation = AskGenerationResult(text: nil, outcome: .timedOut)
        } catch {
            await gate.close()
            generation = AskGenerationResult(text: nil, outcome: .failed)
        }
        try Task.checkCancellation()
        await gate.close()
        return AskWebAnswer(
            question: question,
            generatedText: generation.text,
            citations: evidence.citations,
            sourceFailures: evidence.sourceFailures,
            generationOutcome: generation.outcome)
    }

    private func retrieve(
        _ urls: [URL]
    ) async throws -> AskWebEvidenceUpdate {
        let retrieval = retrieval
        return try await withThrowingTaskGroup(
            of: AskWebIndexedResult.self
        ) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let citation = try await retrieval.retrieve(url)
                        guard Self.isValid(citation, for: url) else {
                            return .failure(index, AskWebSourceFailure(
                                url: url,
                                kind: .transport))
                        }
                        return .citation(index, citation)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        let kind = (error as? AskWebRetrievalError)?
                            .failureKind ?? .transport
                        return .failure(index, AskWebSourceFailure(
                            url: url,
                            kind: kind))
                    }
                }
            }
            var results: [AskWebIndexedResult] = []
            while let result = try await group.next() {
                results.append(result)
            }
            results.sort { $0.index < $1.index }
            return AskWebEvidenceUpdate(
                citations: results.compactMap(\.citation),
                sourceFailures: results.compactMap(\.failure))
        }
    }

    private static func validate(_ request: AskWebRequest) throws -> String {
        switch request.consent {
        case .approvedForSingleRequest:
            break
        }
        guard !request.sourceURLs.isEmpty else {
            throw AskWebRequestError.noSources
        }
        guard request.sourceURLs.count <= maximumSources else {
            throw AskWebRequestError.tooManySources
        }
        guard Set(request.sourceURLs.map(\.absoluteString)).count
                == request.sourceURLs.count
        else { throw AskWebRequestError.duplicateSource }
        guard request.question.utf8.count
                <= AskRequestLimits.maximumQuestionUTF8Bytes,
              request.question.count
                <= AskRequestLimits.maximumQuestionCharacters
        else { throw AskRequestError.questionTooLong }
        let question = request.question.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AskWebRequestError.emptyQuestion }
        try Task.checkCancellation()
        return question
    }

    private static func isValid(
        _ citation: AskWebCitation,
        for requestedURL: URL
    ) -> Bool {
        guard citation.url == requestedURL,
              citation.title.count <= AskWebEvidenceLimits.maximumTitleCharacters,
              citation.title.contains(where: { !$0.isWhitespace }),
              citation.text.count <= AskWebEvidenceLimits.maximumTextCharacters,
              citation.text.utf8.count <= AskWebEvidenceLimits.maximumTextUTF8Bytes,
              citation.text.contains(where: { !$0.isWhitespace }),
              citation.retrievedAt.timeIntervalSinceReferenceDate.isFinite,
              citation.observedDate?.timeIntervalSinceReferenceDate.isFinite
                ?? true
        else { return false }
        switch (citation.observedDate, citation.observedDateKind) {
        case (nil, .unavailable), (.some, .published), (.some, .lastModified):
            break
        case (nil, .published), (nil, .lastModified), (.some, .unavailable):
            return false
        }
        switch citation.freshness {
        case .unknown:
            return true
        case .recent, .stale:
            guard let observedDate = citation.observedDate else { return false }
            return observedDate <= citation.retrievedAt
        }
    }
}

private enum AskWebIndexedResult: Sendable {
    case citation(Int, AskWebCitation)
    case failure(Int, AskWebSourceFailure)

    var index: Int {
        switch self {
        case .citation(let index, _), .failure(let index, _): index
        }
    }

    var citation: AskWebCitation? {
        guard case .citation(_, let citation) = self else { return nil }
        return citation
    }

    var failure: AskWebSourceFailure? {
        guard case .failure(_, let failure) = self else { return nil }
        return failure
    }
}

private actor AskWebAnswerUpdateGate {
    private let citationCount: Int
    private var latestText: String?
    private var lastPublishedText: String?
    private var snapshotCount = 0
    private var isClosed = false
    private var isInvalid = false

    init(citationCount: Int) {
        self.citationCount = citationCount
    }

    func admit(_ update: AskAnswerUpdate) -> AskAnswerUpdate? {
        guard !isClosed, !isInvalid else { return nil }
        snapshotCount += 1
        guard snapshotCount <= AskRequestLimits.maximumAnswerSnapshots,
              let text = validated(update.text),
              latestText.map(text.hasPrefix) ?? true
        else {
            isInvalid = true
            return nil
        }
        latestText = text
        guard WebAnswerCitationPolicy.isValid(
            text,
            citationCount: citationCount),
              text != lastPublishedText
        else { return nil }
        lastPublishedText = text
        return AskAnswerUpdate(text: text)
    }

    func finalize(
        _ returned: String?
    ) -> (text: String?, update: AskAnswerUpdate?) {
        guard !isClosed, !isInvalid, let returned,
              let text = validated(returned),
              latestText.map(text.hasPrefix) ?? true,
              WebAnswerCitationPolicy.isValid(
                  text,
                  citationCount: citationCount)
        else { return (nil, nil) }
        latestText = text
        guard text != lastPublishedText else { return (text, nil) }
        lastPublishedText = text
        return (text, AskAnswerUpdate(text: text))
    }

    func close() {
        isClosed = true
    }

    private func validated(_ value: String) -> String? {
        guard value.count <= AskRequestLimits.maximumAnswerCharacters,
              value.utf8.count <= AskRequestLimits.maximumAnswerUTF8Bytes,
              value.contains(where: { !$0.isWhitespace })
        else { return nil }
        return value
    }
}

enum WebAnswerCitationPolicy {
    static func isValid(_ answer: String, citationCount: Int) -> Bool {
        guard citationCount > 0,
              !answer.localizedCaseInsensitiveContains("http://"),
              !answer.localizedCaseInsensitiveContains("https://")
        else { return false }
        var foundCitation = false
        var index = answer.startIndex
        while index < answer.endIndex {
            guard answer[index] == "[" else {
                index = answer.index(after: index)
                continue
            }
            let start = answer.index(after: index)
            guard let close = answer[start...].firstIndex(of: "]") else {
                index = start
                continue
            }
            let marker = answer[start..<close]
            if !marker.isEmpty, marker.allSatisfy(\.isNumber) {
                guard let value = Int(marker),
                      value >= 1,
                      value <= citationCount
                else { return false }
                foundCitation = true
            }
            index = answer.index(after: close)
        }
        return foundCitation
    }
}
