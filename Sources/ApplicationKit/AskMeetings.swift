import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// A storage-independent instant result for Ask surfaces.
public struct AskSearchResult: Equatable, Sendable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let segmentID: UUID
    public let snippet: String
    public let timestamp: TimeInterval

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        segmentID: UUID,
        snippet: String,
        timestamp: TimeInterval
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentID = segmentID
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// One exact piece of meeting evidence. Presentation can navigate with the
/// aggregate identity and timestamp without receiving a storage record or an
/// IntelligenceKit passage.
public struct AskCitation: Equatable, Sendable {
    public let segmentID: UUID?
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let timestamp: TimeInterval
    public let transcriptRevision: Int
    public let text: String

    public init(
        segmentID: UUID? = nil,
        meetingID: MeetingID,
        meetingTitle: String,
        timestamp: TimeInterval,
        transcriptRevision: Int = 0,
        text: String
    ) {
        self.segmentID = segmentID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.timestamp = timestamp
        self.transcriptRevision = transcriptRevision
        self.text = text
    }
}

/// Answer text is optional by design: evidence remains useful when the local
/// generative model is unavailable or fails, and callers choose localized copy.
public struct AskMeetingAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let citations: [AskCitation]

    public init(
        question: String,
        generatedText: String?,
        citations: [AskCitation]
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
    }
}

/// Retrieval is an internal capability of the application workflow. Real
/// composition uses the hybrid local adapter; tests can inject deterministic
/// evidence without downloading model assets.
public protocol AskMeetingRetrieving: Sendable {
    func search(query: String, limit: Int) async throws -> [AskSearchResult]
    func retrieve(question: String, limit: Int) async throws -> [AskCitation]

    func search(
        query: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult]
    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskCitation]
}

public extension AskMeetingRetrieving {
    func search(
        query: String,
        limit: Int,
        trace _: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        try await search(query: query, limit: limit)
    }

    func retrieve(
        question: String,
        limit: Int,
        trace _: AskPipelineTrace
    ) async throws -> [AskCitation] {
        try await retrieve(question: question, limit: limit)
    }
}

/// Optional local generation. Throwing or returning nil degrades to evidence;
/// retrieval success is never discarded because an answer model is absent.
public protocol AskMeetingAnswering: Sendable {
    func answer(question: String, citations: [AskCitation]) async throws -> String?
}

public enum AskMeetingsRequest: Sendable {
    case search(query: String, limit: Int)
    case evidence(question: String, limit: Int)
    case answer(question: String, limit: Int)
}

public enum AskMeetingsResponse: Equatable, Sendable {
    case search([AskSearchResult])
    case evidence([AskCitation])
    case answer(AskMeetingAnswer)
}

/// The single application boundary for every Ask consumer: instant local FTS,
/// hybrid evidence retrieval, and optional on-device answer generation.
public struct AskMeetings: ApplicationUseCase {
    private let retrieval: any AskMeetingRetrieving
    private let answering: any AskMeetingAnswering
    private let telemetry: AskPipelineTelemetry

    public init(
        retrieval: any AskMeetingRetrieving,
        answering: any AskMeetingAnswering,
        telemetry: AskPipelineTelemetry = .disabled
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.telemetry = telemetry
    }

    public static func local(
        store: MeetingStore,
        semanticRuntime: any SemanticEmbeddingRuntimeClient,
        semanticReadiness: ResolveSemanticCorpusReadiness? = nil,
        pipelineTelemetry: AskPipelineTelemetry = .disabled
    ) -> Self {
        let intelligence = OnDeviceAskMeetingIntelligence()
        return Self(
            retrieval: LocalAskMeetingRetrieval(
                store: store,
                queryExpander: intelligence,
                runtime: semanticRuntime,
                semanticReadiness: semanticReadiness),
            answering: intelligence,
            telemetry: pipelineTelemetry)
    }

    public func execute(
        _ request: AskMeetingsRequest
    ) async throws -> AskMeetingsResponse {
        switch request {
        case .search(let query, let limit):
            return .search(try await search(query, limit: limit))
        case .evidence(let question, let limit):
            return .evidence(try await evidence(question, limit: limit))
        case .answer(let question, let limit):
            return .answer(try await answer(question, limit: limit))
        }
    }

    public func search(
        _ query: String,
        limit: Int = 6
    ) async throws -> [AskSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        return try await telemetry.measure(.search) { trace in
            let results = try await retrieval.search(
                query: query,
                limit: limit,
                trace: trace)
            if !results.isEmpty {
                trace.reach(.firstEvidence)
            }
            return results
        }
    }

    public func evidence(
        _ question: String,
        limit: Int = 6
    ) async throws -> [AskCitation] {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, limit > 0 else { return [] }
        return try await telemetry.measure(.evidence) { trace in
            let citations = try await retrieval.retrieve(
                question: question,
                limit: limit,
                trace: trace)
            if !citations.isEmpty {
                trace.reach(.firstEvidence)
            }
            return citations
        }
    }

    public func answer(
        _ question: String,
        limit: Int = 6
    ) async throws -> AskMeetingAnswer {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, limit > 0 else {
            return AskMeetingAnswer(
                question: question,
                generatedText: nil,
                citations: [])
        }
        return try await telemetry.measure(.answer) { trace in
            let citations = try await retrieval.retrieve(
                question: question,
                limit: limit,
                trace: trace)
            try Task.checkCancellation()
            guard !citations.isEmpty else {
                return AskMeetingAnswer(
                    question: question,
                    generatedText: nil,
                    citations: [])
            }
            trace.reach(.firstEvidence)
            let generatedText: String?
            do {
                generatedText = try await answering.answer(
                    question: question,
                    citations: citations)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                generatedText = nil
            }
            try Task.checkCancellation()
            if generatedText?.contains(where: { !$0.isWhitespace }) == true {
                // The current answer capability returns one complete String,
                // so its first token becomes observable at this boundary.
                trace.reach(.firstToken)
            }
            return AskMeetingAnswer(
                question: question,
                generatedText: generatedText,
                citations: citations)
        }
    }
}

public protocol AskQueryExpanding: Sendable {
    func expand(_ question: String) async -> [String]
}

/// Concrete local intelligence adapter shared by retrieval expansion and final
/// answer generation. It is inert when Foundation Models is unavailable.
public struct OnDeviceAskMeetingIntelligence: AskMeetingAnswering, AskQueryExpanding {
    public init() {}

    public func expand(_ question: String) async -> [String] {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return [question] }
        return await RAGAnswerer().expandQuery(question)
    }

    public func answer(
        question: String,
        citations: [AskCitation]
    ) async throws -> String? {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return nil }
        let passages = citations.map { citation in
            RAGPassage(
                segmentID: citation.segmentID,
                meetingID: citation.meetingID,
                meetingTitle: citation.meetingTitle,
                timestamp: citation.timestamp,
                text: citation.text)
        }
        return try await RAGAnswerer().answer(
            question: question,
            passages: passages)
    }
}
