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

/// Progressive evidence ownership for presentation surfaces. Lexical evidence
/// may render immediately; fused evidence is the immutable set used by answer
/// generation.
public enum AskEvidencePhase: String, Equatable, Sendable {
    case lexical
    case fused
}

public struct AskEvidenceUpdate: Equatable, Sendable {
    public let phase: AskEvidencePhase
    public let citations: [AskCitation]

    public init(
        phase: AskEvidencePhase,
        citations: [AskCitation]
    ) {
        self.phase = phase
        self.citations = citations
    }
}

public typealias AskEvidenceReceiver = @Sendable (AskEvidenceUpdate) async -> Void

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
    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
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

    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        let citations = try await retrieve(
            question: question,
            limit: limit,
            trace: trace)
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: citations))
        return citations
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
    private let graphFacts: (any AskGraphFactRetrieving)?
    private let graphFilterResolver: (any AskGraphFactFilterResolving)?
    private let telemetry: AskPipelineTelemetry

    public init(
        retrieval: any AskMeetingRetrieving,
        answering: any AskMeetingAnswering,
        graphFacts: (any AskGraphFactRetrieving)? = nil,
        graphFilterResolver: (any AskGraphFactFilterResolving)? = nil,
        telemetry: AskPipelineTelemetry = .disabled
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.graphFacts = graphFacts
        self.graphFilterResolver = graphFilterResolver
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
            graphFacts: LocalAskGraphFactRetrieval(store: store),
            graphFilterResolver: LocalAskGraphFactFilterResolver(store: store),
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

    /// Retrieves transcript citations and one already-resolved graph query as
    /// independent lanes. Ordinary graph failure is disclosed without erasing
    /// transcript evidence; cancellation still cancels the complete request.
    public func evidenceBundle(
        _ question: String,
        limit: Int = 6,
        graphQuery: AskGraphFactQuery? = nil,
        graphFilter: AskGraphFactFilterRequest? = nil
    ) async throws -> AskEvidenceBundle {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, limit > 0 else {
            return AskEvidenceBundle(
                transcriptCitations: [],
                graphFacts: .notRequested)
        }

        async let graphOutcome = graphFactOutcome(
            for: graphQuery,
            filter: graphFilter)
        let citations = try await evidence(question, limit: limit)
        let graphFacts = try await graphOutcome
        return AskEvidenceBundle(
            transcriptCitations: citations,
            graphFacts: graphFacts)
    }

    public func answer(
        _ question: String,
        limit: Int = 6
    ) async throws -> AskMeetingAnswer {
        try await answer(
            question,
            limit: limit,
            onEvidence: { _ in })
    }

    public func answer(
        _ question: String,
        limit: Int = 6,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, limit > 0 else {
            return AskMeetingAnswer(
                question: question,
                generatedText: nil,
                citations: [])
        }
        return try await telemetry.measure(.answer) { trace in
            let milestone = AskFirstEvidenceMilestone()
            let citations = try await retrieval.retrieve(
                question: question,
                limit: limit,
                trace: trace,
                onEvidence: { update in
                    await milestone.reachIfNeeded(
                        for: update.citations,
                        trace: trace)
                    await onEvidence(update)
                })
            try Task.checkCancellation()
            guard !citations.isEmpty else {
                return AskMeetingAnswer(
                    question: question,
                    generatedText: nil,
                    citations: [])
            }
            await milestone.reachIfNeeded(for: citations, trace: trace)
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

    private func graphFactOutcome(
        for query: AskGraphFactQuery?,
        filter: AskGraphFactFilterRequest?
    ) async throws -> AskGraphFactLaneOutcome {
        guard let query else {
            return filter == nil
                ? .notRequested
                : .result(.abstained(.invalidQuery))
        }
        guard let graphFacts else { return .unavailable }
        do {
            if let filter {
                guard let graphFilterResolver else { return .unavailable }
                switch try await graphFilterResolver.resolve(filter) {
                case .resolved(let value):
                    switch value.applying(to: query) {
                    case .query(let filteredQuery):
                        return .result(try await graphFacts.retrieve(filteredQuery))
                    case .abstained(let reason):
                        return .result(.abstained(reason))
                    }
                case .abstained(let reason):
                    return .result(.abstained(reason))
                }
            }
            return .result(try await graphFacts.retrieve(query))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .unavailable
        }
    }
}

private actor AskFirstEvidenceMilestone {
    private var didReach = false

    func reachIfNeeded(
        for citations: [AskCitation],
        trace: AskPipelineTrace
    ) {
        guard !didReach, !citations.isEmpty else { return }
        didReach = true
        trace.reach(.firstEvidence)
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
