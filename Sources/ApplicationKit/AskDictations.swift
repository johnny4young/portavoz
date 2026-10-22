import Foundation
import PortavozCore

/// One saved dictation, cited by its own identity rather than a meeting moment.
public struct AskDictationCitation: Equatable, Identifiable, Sendable {
    public var id: DictationRecordID { dictationID }
    public let dictationID: DictationRecordID
    public let createdAt: Date
    public let applicationName: String?
    public let delivery: DictationRecordDelivery
    public let text: String

    public init(
        dictationID: DictationRecordID,
        createdAt: Date,
        applicationName: String?,
        delivery: DictationRecordDelivery,
        text: String
    ) {
        self.dictationID = dictationID
        self.createdAt = createdAt
        self.applicationName = applicationName
        self.delivery = delivery
        self.text = text
    }
}

/// What a listing covered, so the answer can name it, even when it is empty.
public struct AskDictationScope: Equatable, Sendable {
    public let period: DateInterval?
    public let applicationName: String?
    /// The question asked for a summary, so the engine writes one above the list.
    public let summarize: Bool

    public init(period: DateInterval?, applicationName: String?, summarize: Bool) {
        self.period = period
        self.applicationName = applicationName
        self.summarize = summarize
    }
}

public enum AskDictationEvidence: Equatable, Sendable {
    /// The history is off, so nothing was read.
    case historyOff
    /// Dictations that match the question's words.
    case found([AskDictationCitation])
    /// The newest dictations in the question's period or app; all stay cited.
    case listed([AskDictationCitation], AskDictationScope)
}

public typealias AskDictationEvidenceReceiver = @Sendable (
    [AskDictationCitation]
) async -> Void

public protocol AskDictationRetrieving: Sendable {
    func retrieve(question: String, limit: Int) async throws -> AskDictationEvidence
}

public protocol AskDictationAnswering: Sendable {
    /// Returns raw numbered-citation prose. nil means the selected engine is
    /// unavailable; the caller must not fall through to another provider.
    func answer(
        question: String,
        citations: [AskDictationCitation]
    ) async throws -> String?
}

public struct AskDictationAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let citations: [AskDictationCitation]
    public let generationOutcome: AskGenerationOutcome
    public let historyIsOff: Bool
    /// Set when the answer lists dictations rather than searching their words.
    public let listing: AskDictationScope?

    public init(
        question: String,
        generatedText: String?,
        citations: [AskDictationCitation],
        generationOutcome: AskGenerationOutcome,
        historyIsOff: Bool = false,
        listing: AskDictationScope? = nil
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
        self.generationOutcome = generationOutcome
        self.historyIsOff = historyIsOff
        self.listing = listing
    }
}

public enum AskDictationLimits {
    public static let maximumResultCount = 12
    public static let maximumCitationCharacters = 4_000
    public static let maximumCitationUTF8Bytes = 16_000
    public static let maximumAggregateCharacters = 8_000
    public static let maximumAggregateUTF8Bytes = 32_000
}

public struct AskDictationsRequest: Sendable {
    public let question: String
    public let limit: Int

    public init(question: String, limit: Int = 6) {
        self.question = question
        self.limit = limit
    }
}

/// Ask over the private dictation history. Nothing is read while the history
/// is off, and exact dictations survive an answer-engine failure.
public struct AskDictations: ApplicationUseCase {
    private let retrieval: any AskDictationRetrieving
    private let answering: any AskDictationAnswering
    private let telemetry: AskPipelineTelemetry
    private let answerTimeout: Duration
    var answerClock: AskAnswerClock = .continuous

    public init(
        retrieval: any AskDictationRetrieving,
        answering: any AskDictationAnswering,
        telemetry: AskPipelineTelemetry = .disabled,
        answerTimeout: Duration = .seconds(8)
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.telemetry = telemetry
        self.answerTimeout = answerTimeout > .zero ? answerTimeout : .seconds(8)
    }

    public func execute(_ request: AskDictationsRequest) async throws -> AskDictationAnswer {
        try await answer(request.question, limit: request.limit)
    }

    public func answer(
        _ rawQuestion: String,
        limit: Int = 6,
        onEvidence: @escaping AskDictationEvidenceReceiver = { _ in }
    ) async throws -> AskDictationAnswer {
        let question = try AskTypedSource.validatedQuestion(
            rawQuestion,
            limit: limit,
            maximumLimit: AskDictationLimits.maximumResultCount)
        guard let question else {
            return AskDictationAnswer(
                question: rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines),
                generatedText: nil,
                citations: [],
                generationOutcome: .insufficientEvidence)
        }
        return try await telemetry.measure(.answer) { trace in
            try await answer(question, limit: limit, trace: trace, onEvidence: onEvidence)
        }
    }

    private func answer(
        _ question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskDictationEvidenceReceiver
    ) async throws -> AskDictationAnswer {
        let evidence = try await retrieval.retrieve(question: question, limit: limit)
        try Task.checkCancellation()
        let returned: [AskDictationCitation]
        let listing: AskDictationScope?
        switch evidence {
        case .historyOff:
            return AskDictationAnswer(
                question: question,
                generatedText: nil,
                citations: [],
                generationOutcome: .notRequested,
                historyIsOff: true)
        case .found(let citations):
            (returned, listing) = (citations, nil)
        case .listed(let citations, let scope):
            (returned, listing) = (citations, scope)
        }
        guard let citations = Self.validated(returned, limit: limit) else {
            throw AskDictationEvidenceError.invalid
        }
        guard !citations.isEmpty else {
            return response(question: question, citations: [], outcome: .insufficientEvidence, listing: listing)
        }
        trace.reach(.firstEvidence)
        await onEvidence(citations)
        try Task.checkCancellation()
        // A plain listing is the answer itself; only a requested summary needs the engine.
        if let listing, !listing.summarize {
            return response(question: question, citations: citations, outcome: .notRequested, listing: listing)
        }
        return try await generate(question: question, citations: citations, listing: listing, trace: trace)
    }

    private func generate(
        question: String,
        citations: [AskDictationCitation],
        listing: AskDictationScope?,
        trace: AskPipelineTrace
    ) async throws -> AskDictationAnswer {
        do {
            let deadline = AskAnswerDeadline(after: answerTimeout, clock: answerClock)
            let raw = try await withAskTimeout(
                deadline,
                onTimeout: {},
                operation: { try await answering.answer(question: question, citations: citations) })
            try Task.checkCancellation()
            guard let raw else {
                return response(question: question, citations: citations, outcome: .unavailable, listing: listing)
            }
            guard let admitted = AskTypedSource.admitAnswer(raw, citations: citations) else {
                return response(
                    question: question, citations: citations, outcome: .insufficientEvidence, listing: listing)
            }
            try deadline.check()
            trace.reach(.firstToken)
            return AskDictationAnswer(
                question: question,
                generatedText: admitted.text,
                citations: listing == nil ? admitted.citations : citations,
                generationOutcome: .generated,
                listing: listing)
        } catch is CancellationError {
            throw CancellationError()
        } catch is AskTimeoutError {
            return response(question: question, citations: citations, outcome: .timedOut, listing: listing)
        } catch {
            return response(question: question, citations: citations, outcome: .failed, listing: listing)
        }
    }

    private func response(
        question: String,
        citations: [AskDictationCitation],
        outcome: AskGenerationOutcome,
        listing: AskDictationScope? = nil
    ) -> AskDictationAnswer {
        AskDictationAnswer(
            question: question,
            generatedText: nil,
            citations: citations,
            generationOutcome: outcome,
            listing: listing)
    }

    /// Fails closed on evidence the retrieval contract does not allow.
    static func validated(
        _ citations: [AskDictationCitation],
        limit: Int
    ) -> [AskDictationCitation]? {
        guard citations.count <= limit else { return nil }
        var identities = Set<DictationRecordID>()
        var characters = 0
        var bytes = 0
        for citation in citations {
            characters += citation.text.count
            bytes += citation.text.utf8.count
            guard identities.insert(citation.dictationID).inserted,
                  citation.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  citation.text.contains(where: { !$0.isWhitespace }),
                  citation.text.count <= AskDictationLimits.maximumCitationCharacters,
                  citation.text.utf8.count <= AskDictationLimits.maximumCitationUTF8Bytes,
                  (citation.applicationName?.count ?? 0) <= DictationRecord.maximumLabelLength,
                  characters <= AskDictationLimits.maximumAggregateCharacters,
                  bytes <= AskDictationLimits.maximumAggregateUTF8Bytes
            else { return nil }
        }
        return citations
    }
}

private enum AskDictationEvidenceError: Error {
    case invalid
}
