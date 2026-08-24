import Foundation
import IntelligenceKit
import PortavozCore

public enum AskNoteAuthor: String, Equatable, Sendable {
    /// Raw D28 context notes are explicitly written by the local app user.
    case localUser = "local-user"
}

public enum AskNoteProvenance: String, Equatable, Sendable {
    /// Exact raw `contextItem.kind == .note` identity. Enhanced/model output
    /// has a different table and cannot claim this provenance.
    case userContextItem
}

/// One exact user-authored note, deliberately not a transcript citation.
public struct AskNoteCitation: Equatable, Identifiable, Sendable {
    public var id: UUID { noteID }
    public let noteID: UUID
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let author: AskNoteAuthor
    public let authoredAt: Date
    public let timestamp: TimeInterval
    public let text: String
    public let provenance: AskNoteProvenance

    public init(
        noteID: UUID,
        meetingID: MeetingID,
        meetingTitle: String,
        author: AskNoteAuthor,
        authoredAt: Date,
        timestamp: TimeInterval,
        text: String,
        provenance: AskNoteProvenance
    ) {
        self.noteID = noteID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.author = author
        self.authoredAt = authoredAt
        self.timestamp = timestamp
        self.text = text
        self.provenance = provenance
    }
}

public enum AskNoteEvidencePhase: String, Equatable, Sendable {
    case lexical
    case fused
}

public struct AskNoteEvidenceUpdate: Equatable, Sendable {
    public let phase: AskNoteEvidencePhase
    public let citations: [AskNoteCitation]

    public init(
        phase: AskNoteEvidencePhase,
        citations: [AskNoteCitation]
    ) {
        self.phase = phase
        self.citations = citations
    }
}

public typealias AskNoteEvidenceReceiver = @Sendable (
    AskNoteEvidenceUpdate
) async -> Void

public protocol AskNoteRetrieving: Sendable {
    func retrieve(
        question: String,
        limit: Int,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async throws -> [AskNoteCitation]
}

public protocol AskNoteAnswering: Sendable {
    /// Returns raw numbered-citation prose. nil means the selected engine is
    /// unavailable; the caller must not fall through to another provider.
    func answer(
        question: String,
        citations: [AskNoteCitation]
    ) async throws -> String?
}

public struct AskNoteAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let citations: [AskNoteCitation]
    public let generationOutcome: AskGenerationOutcome

    public init(
        question: String,
        generatedText: String?,
        citations: [AskNoteCitation],
        generationOutcome: AskGenerationOutcome
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
        self.generationOutcome = generationOutcome
    }
}

public enum AskNoteLimits {
    public static let maximumResultCount = 12
    public static let maximumCitationCharacters = 4_000
    public static let maximumCitationUTF8Bytes = 16_000
    public static let maximumAggregateCharacters = 8_000
    public static let maximumAggregateUTF8Bytes = 32_000
}

public struct AskNotesRequest: Sendable {
    public let question: String
    public let limit: Int

    public init(question: String, limit: Int = 6) {
        self.question = question
        self.limit = limit
    }
}

/// Explicit local-note Ask. Retrieval, evidence publication, and generation
/// remain one cancellable request; exact evidence survives provider failure.
public struct AskNotes: ApplicationUseCase {
    private let retrieval: any AskNoteRetrieving
    private let answering: any AskNoteAnswering
    private let telemetry: AskPipelineTelemetry
    private let answerTimeout: Duration

    public init(
        retrieval: any AskNoteRetrieving,
        answering: any AskNoteAnswering,
        telemetry: AskPipelineTelemetry = .disabled,
        answerTimeout: Duration = .seconds(8)
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.telemetry = telemetry
        self.answerTimeout = answerTimeout > .zero
            ? answerTimeout
            : .seconds(8)
    }

    public func execute(_ request: AskNotesRequest) async throws -> AskNoteAnswer {
        try await answer(request.question, limit: request.limit)
    }

    public func answer(
        _ rawQuestion: String,
        limit: Int = 6,
        onEvidence: @escaping AskNoteEvidenceReceiver = { _ in }
    ) async throws -> AskNoteAnswer {
        let question = try Self.validatedQuestion(rawQuestion, limit: limit)
        guard let question else {
            return AskNoteAnswer(
                question: rawQuestion.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                generatedText: nil,
                citations: [],
                generationOutcome: .insufficientEvidence)
        }
        return try await telemetry.measure(.answer) { trace in
            try await answer(
                question,
                limit: limit,
                trace: trace,
                onEvidence: onEvidence)
        }
    }

    private func answer(
        _ question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskNoteEvidenceReceiver
    ) async throws -> AskNoteAnswer {
        let gate = AskNoteEvidenceGate(limit: limit)
        let firstEvidence = AskNoteFirstEvidenceMilestone(trace: trace)
        let returned = try await retrieval.retrieve(
            question: question,
            limit: limit
        ) { update in
            guard !Task.isCancelled,
                  let admitted = await gate.admit(update)
            else { return }
            await firstEvidence.reachIfNeeded(admitted.citations)
            await onEvidence(admitted)
        }
        try Task.checkCancellation()
        let finalized = try await gate.finalize(returned)
        if let update = finalized.update {
            await firstEvidence.reachIfNeeded(update.citations)
            await onEvidence(update)
        }
        guard !finalized.citations.isEmpty else {
            await gate.close()
            return AskNoteAnswer(
                question: question,
                generatedText: nil,
                citations: [],
                generationOutcome: .insufficientEvidence)
        }

        let result = try await generate(
            question: question,
            citations: finalized.citations,
            trace: trace)
        await gate.close()
        return result
    }

    private func generate(
        question: String,
        citations: [AskNoteCitation],
        trace: AskPipelineTrace
    ) async throws -> AskNoteAnswer {
        do {
            let raw = try await withAskTimeout(
                answerTimeout,
                onTimeout: {},
                operation: {
                    try await answering.answer(
                        question: question,
                        citations: citations)
                })
            try Task.checkCancellation()
            guard let raw else {
                return response(
                    question: question,
                    citations: citations,
                    outcome: .unavailable)
            }
            guard let admitted = Self.admitAnswer(raw, citations: citations) else {
                return response(
                    question: question,
                    citations: citations,
                    outcome: .insufficientEvidence)
            }
            trace.reach(.firstToken)
            return AskNoteAnswer(
                question: question,
                generatedText: admitted.text,
                citations: admitted.citations,
                generationOutcome: .generated)
        } catch is CancellationError {
            throw CancellationError()
        } catch is AskTimeoutError {
            return response(
                question: question,
                citations: citations,
                outcome: .timedOut)
        } catch {
            return response(
                question: question,
                citations: citations,
                outcome: .failed)
        }
    }

    private func response(
        question: String,
        citations: [AskNoteCitation],
        outcome: AskGenerationOutcome
    ) -> AskNoteAnswer {
        AskNoteAnswer(
            question: question,
            generatedText: nil,
            citations: citations,
            generationOutcome: outcome)
    }

    private static func admitAnswer(
        _ raw: String,
        citations: [AskNoteCitation]
    ) -> (text: String, citations: [AskNoteCitation])? {
        guard raw.count <= AskRequestLimits.maximumAnswerCharacters,
              raw.utf8.count <= AskRequestLimits.maximumAnswerUTF8Bytes,
              let indexes = NumberedCitationAnswer.exactIndexes(
                in: raw,
                evidenceCount: citations.count),
              let text = CompanionAnswer.usable(raw)
        else { return nil }
        return (text, indexes.map { citations[$0] })
    }

    private static func validatedQuestion(
        _ value: String,
        limit: Int
    ) throws -> String? {
        guard value.count <= AskRequestLimits.maximumQuestionCharacters,
              value.utf8.count <= AskRequestLimits.maximumQuestionUTF8Bytes
        else { throw AskRequestError.questionTooLong }
        guard limit > 0, limit <= AskNoteLimits.maximumResultCount else {
            if limit <= 0 { return nil }
            throw AskRequestError.resultLimitExceeded
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return trimmed.isEmpty ? nil : trimmed
    }
}

private actor AskNoteEvidenceGate {
    private let limit: Int
    private var isClosed = false
    private var isInvalid = false
    private var fused: [AskNoteCitation]?
    private var lexical: [AskNoteCitation]?

    init(limit: Int) {
        self.limit = limit
    }

    func admit(_ update: AskNoteEvidenceUpdate) -> AskNoteEvidenceUpdate? {
        guard !isClosed, !isInvalid else { return nil }
        guard let citations = validated(update.citations) else {
            isInvalid = true
            return nil
        }
        switch update.phase {
        case .lexical:
            guard fused == nil, lexical != citations else { return nil }
            lexical = citations
            return AskNoteEvidenceUpdate(phase: .lexical, citations: citations)
        case .fused:
            guard fused == nil else { return nil }
            fused = citations
            return AskNoteEvidenceUpdate(phase: .fused, citations: citations)
        }
    }

    func finalize(
        _ returned: [AskNoteCitation]
    ) throws -> (
        citations: [AskNoteCitation],
        update: AskNoteEvidenceUpdate?
    ) {
        guard !isClosed, !isInvalid,
              let citations = validated(returned)
        else { throw AskNoteEvidenceError.invalid }
        if let fused {
            guard fused == citations else { throw AskNoteEvidenceError.mismatch }
            return (fused, nil)
        }
        fused = citations
        return (
            citations,
            AskNoteEvidenceUpdate(phase: .fused, citations: citations))
    }

    func close() {
        isClosed = true
    }

    private func validated(
        _ citations: [AskNoteCitation]
    ) -> [AskNoteCitation]? {
        guard citations.count <= limit else { return nil }
        var identities = Set<UUID>()
        var characters = 0
        var bytes = 0
        for citation in citations {
            characters += citation.text.count
            bytes += citation.text.utf8.count
            guard identities.insert(citation.noteID).inserted,
                  citation.author == .localUser,
                  citation.provenance == .userContextItem,
                  citation.timestamp.isFinite,
                  citation.timestamp >= 0,
                  citation.authoredAt.timeIntervalSinceReferenceDate.isFinite,
                  Self.validText(
                    citation.meetingTitle,
                    characters: AskRequestLimits.maximumMeetingTitleCharacters,
                    bytes: AskRequestLimits.maximumMeetingTitleCharacters * 8),
                  Self.validText(
                    citation.text,
                    characters: AskNoteLimits.maximumCitationCharacters,
                    bytes: AskNoteLimits.maximumCitationUTF8Bytes),
                  characters <= AskNoteLimits.maximumAggregateCharacters,
                  bytes <= AskNoteLimits.maximumAggregateUTF8Bytes
            else { return nil }
        }
        return citations
    }

    private static func validText(
        _ value: String,
        characters: Int,
        bytes: Int
    ) -> Bool {
        value.count <= characters
            && value.utf8.count <= bytes
            && value.contains(where: { !$0.isWhitespace })
    }
}

private actor AskNoteFirstEvidenceMilestone {
    private let trace: AskPipelineTrace
    private var reached = false

    init(trace: AskPipelineTrace) {
        self.trace = trace
    }

    func reachIfNeeded(_ citations: [AskNoteCitation]) {
        guard !reached, !citations.isEmpty else { return }
        reached = true
        trace.reach(.firstEvidence)
    }
}

private enum AskNoteEvidenceError: Error {
    case invalid
    case mismatch
}
