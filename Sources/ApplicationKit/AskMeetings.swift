import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

/// A storage-independent instant result for Ask surfaces.
public struct AskSearchResult: Equatable, Sendable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let segmentID: UUID
    public let sourceSegmentIDs: [UUID]
    public let snippet: String
    public let timestamp: TimeInterval

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        segmentID: UUID,
        sourceSegmentIDs: [UUID]? = nil,
        snippet: String,
        timestamp: TimeInterval
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? [segmentID]
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// One exact piece of meeting evidence. Presentation can navigate with the
/// aggregate identity and timestamp without receiving a storage record or an
/// IntelligenceKit passage.
public struct AskCitation: Equatable, Sendable {
    /// Stable visible retrieval-unit identity. It may be a split part or merge
    /// correction rather than an accepted segment.
    public let segmentID: UUID?
    public let sourceSegmentIDs: [UUID]
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let timestamp: TimeInterval
    public let transcriptRevision: Int
    public let text: String

    public init(
        segmentID: UUID? = nil,
        sourceSegmentIDs: [UUID]? = nil,
        meetingID: MeetingID,
        meetingTitle: String,
        timestamp: TimeInterval,
        transcriptRevision: Int = 0,
        text: String
    ) {
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? segmentID.map { [$0] } ?? []
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
    public let generationOutcome: AskGenerationOutcome

    public init(
        question: String,
        generatedText: String?,
        citations: [AskCitation],
        generationOutcome: AskGenerationOutcome? = nil
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
        self.generationOutcome = generationOutcome
            ?? (generatedText == nil ? .unavailable : .generated)
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
    func answer(
        question: String,
        citations: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String?
}

public extension AskMeetingAnswering {
    func answer(
        question: String,
        citations: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        let text = try await answer(question: question, citations: citations)
        if let text {
            await onAnswer(AskAnswerUpdate(text: text))
        }
        return text
    }
}

/// Opt-in answer generation over the independent transcript and graph lanes.
/// Keeping this port separate preserves the released transcript-only provider
/// and makes fact-aware adoption explicit at every composition root.
public protocol AskEvidenceBundleAnswering: Sendable {
    func answer(
        question: String,
        evidence: AskSynthesisInput
    ) async throws -> String?
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
    private let bundleAnswering: (any AskEvidenceBundleAnswering)?
    private let graphFacts: (any AskGraphFactRetrieving)?
    private let graphFilterResolver: (any AskGraphFactFilterResolving)?
    private let telemetry: AskPipelineTelemetry
    private let answerTimeout: Duration

    public init(
        retrieval: any AskMeetingRetrieving,
        answering: any AskMeetingAnswering,
        bundleAnswering: (any AskEvidenceBundleAnswering)? = nil,
        graphFacts: (any AskGraphFactRetrieving)? = nil,
        graphFilterResolver: (any AskGraphFactFilterResolving)? = nil,
        telemetry: AskPipelineTelemetry = .disabled,
        answerTimeout: Duration = .seconds(8)
    ) {
        self.retrieval = retrieval
        self.answering = answering
        self.bundleAnswering = bundleAnswering
        self.graphFacts = graphFacts
        self.graphFilterResolver = graphFilterResolver
        self.telemetry = telemetry
        self.answerTimeout = answerTimeout > .zero
            ? answerTimeout
            : .seconds(8)
    }

    public static func local(
        store: MeetingStore,
        semanticRuntime: any SemanticEmbeddingRuntimeClient,
        semanticReadiness: ResolveSemanticCorpusReadiness? = nil,
        pipelineTelemetry: AskPipelineTelemetry = .disabled,
        answering: any AskMeetingAnswering = OnDeviceAskMeetingIntelligence()
    ) -> Self {
        let intelligence = OnDeviceAskMeetingIntelligence()
        return Self(
            retrieval: LocalAskMeetingRetrieval(
                store: store,
                queryExpander: intelligence,
                runtime: semanticRuntime,
                semanticReadiness: semanticReadiness),
            answering: answering,
            bundleAnswering: intelligence,
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
        guard let query = try Self.validatedRequest(query, limit: limit) else {
            return []
        }
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
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return []
        }
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
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return AskEvidenceBundle(
                transcriptCitations: [],
                graphFacts: .notRequested)
        }

        return try await telemetry.measure(.evidence) { trace in
            try await retrieveEvidenceBundle(
                question: question,
                limit: limit,
                graphQuery: graphQuery,
                graphFilter: graphFilter,
                trace: trace)
        }
    }

    /// Generates from the explicit transcript + graph bundle while returning
    /// the exact source material unchanged. Existing released Ask paths keep
    /// using transcript-only `answer`; callers must opt into a graph job.
    public func answerBundle(
        _ question: String,
        limit: Int = 6,
        graphQuery: AskGraphFactQuery,
        graphFilter: AskGraphFactFilterRequest? = nil
    ) async throws -> AskEvidenceBundleAnswer {
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return AskEvidenceBundleAnswer(
                question: question,
                generatedText: nil,
                evidence: AskEvidenceBundle(
                    transcriptCitations: [],
                    graphFacts: .notRequested))
        }
        return try await telemetry.measure(.answer) { trace in
            let bundle = try await retrieveEvidenceBundle(
                question: question,
                limit: limit,
                graphQuery: graphQuery,
                graphFilter: graphFilter,
                trace: trace)
            try Task.checkCancellation()
            let input = bundle.synthesisInput.selecting()
            let generatedText = try await generateBundleAnswer(
                question: question,
                evidence: input)
            try Task.checkCancellation()
            if generatedText?.contains(where: { !$0.isWhitespace }) == true {
                trace.reach(.firstToken)
            }
            return AskEvidenceBundleAnswer(
                question: question,
                generatedText: generatedText,
                evidence: bundle)
        }
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
        try await answer(
            question,
            limit: limit,
            onEvidence: onEvidence,
            onAnswer: { _ in })
    }

    public func answer(
        _ question: String,
        limit: Int = 6,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return AskMeetingAnswer(
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                generatedText: nil,
                citations: [],
                generationOutcome: .notRequested)
        }
        return try await telemetry.measure(.answer) { trace in
            try await answerProgressively(
                question: question,
                limit: limit,
                trace: trace,
                onEvidence: onEvidence,
                onAnswer: onAnswer)
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

    private func retrieveEvidenceBundle(
        question: String,
        limit: Int,
        graphQuery: AskGraphFactQuery?,
        graphFilter: AskGraphFactFilterRequest?,
        trace: AskPipelineTrace
    ) async throws -> AskEvidenceBundle {
        async let graphOutcome = graphFactOutcome(
            for: graphQuery,
            filter: graphFilter)
        let citations = try await retrieval.retrieve(
            question: question,
            limit: limit,
            trace: trace)
        if !citations.isEmpty {
            trace.reach(.firstEvidence)
        }
        let graphFacts = try await graphOutcome
        try Task.checkCancellation()
        let bundle = AskEvidenceBundle(
            transcriptCitations: citations,
            graphFacts: graphFacts)
        return bundle
    }

    private func generateTranscriptAnswer(
        question: String,
        citations: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws -> AskGenerationResult {
        guard !citations.isEmpty else {
            return AskGenerationResult(text: nil, outcome: .notRequested)
        }
        do {
            let text = try await withAskTimeout(
                answerTimeout,
                onTimeout: onTimeout
            ) { [answering] in
                try await answering.answer(
                    question: question,
                    citations: citations,
                    onAnswer: onAnswer)
            }
            return AskGenerationResult(
                text: text,
                outcome: text == nil ? .unavailable : .generated)
        } catch is CancellationError {
            throw CancellationError()
        } catch is AskTimeoutError {
            return AskGenerationResult(text: nil, outcome: .timedOut)
        } catch {
            return AskGenerationResult(text: nil, outcome: .failed)
        }
    }

    private func generateBundleAnswer(
        question: String,
        evidence: AskSynthesisInput
    ) async throws -> String? {
        guard evidence.isFactAwareGenerationReady,
              let bundleAnswering
        else { return nil }
        do {
            return try await bundleAnswering.answer(
                question: question,
                evidence: evidence)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func validatedRequest(
        _ value: String,
        limit: Int
    ) throws -> String? {
        guard value.utf8.count <= AskRequestLimits.maximumQuestionUTF8Bytes,
              value.count <= AskRequestLimits.maximumQuestionCharacters
        else { throw AskRequestError.questionTooLong }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, limit > 0 else { return nil }
        guard limit <= AskRequestLimits.maximumResultCount else {
            throw AskRequestError.resultLimitExceeded
        }
        try Task.checkCancellation()
        return value
    }
}

public protocol AskQueryExpanding: Sendable {
    func expand(_ question: String) async throws -> [String]
}

/// Concrete local intelligence adapter shared by retrieval expansion and final
/// answer generation. It is inert when Foundation Models is unavailable.
public struct OnDeviceAskMeetingIntelligence:
    AskMeetingAnswering,
    AskEvidenceBundleAnswering,
    AskQueryExpanding {
    public init() {}

    public func expand(_ question: String) async throws -> [String] {
        try Task.checkCancellation()
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return [question] }
        return try await RAGAnswerer().expandQuery(question)
    }

    public func answer(
        question: String,
        citations: [AskCitation]
    ) async throws -> String? {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return nil }
        return try await RAGAnswerer().answer(
            question: question,
            passages: citations.map(Self.ragPassage))
    }

    public func answer(
        question: String,
        citations: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return nil }
        return try await RAGAnswerer().streamAnswer(
            question: question,
            passages: citations.map(Self.ragPassage),
            onSnapshot: { text in
                await onAnswer(AskAnswerUpdate(text: text))
            })
    }

    public func answer(
        question: String,
        evidence: AskSynthesisInput
    ) async throws -> String? {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil,
              evidence.isFactAwareGenerationReady,
              case .facts(let graphPage) = evidence.graphFacts,
              let selection = evidence.selection
        else { return nil }
        let facts = graphPage.facts.map { graphFact in
            RAGFact(
                kind: graphFact.fact.kind,
                subjectText: graphFact.fact.subjectText,
                objectText: graphFact.fact.objectText,
                status: graphFact.fact.status,
                occurredAt: graphFact.fact.occurredAt,
                primarySourceSegmentID:
                    graphFact.fact.primaryEvidenceSegmentID,
                sources: graphFact.sourceSegments.map(Self.ragPassage))
        }
        return try await RAGAnswerer().answer(
            question: question,
            context: RAGAnswerContext(
                transcriptPassages: evidence.transcriptCitations.map(
                    Self.ragPassage),
                factPage: RAGFactPage(
                    facts: facts,
                    hasMore: graphPage.hasMore,
                    projectionGeneration: graphPage.projectionGeneration,
                    omittedStaleCount: graphPage.omittedStaleCount,
                    omittedUnavailableCount:
                        graphPage.omittedUnavailableCount,
                    selectionOmittedCount:
                        graphPage.selectionOmittedCount),
                selection: RAGAnswerSelectionDisclosure(
                    transcriptCandidateCount:
                        selection.transcriptCandidateCount,
                    selectedTranscriptCount:
                        selection.selectedTranscriptCount,
                    graphFactCandidateCount:
                        selection.graphFactCandidateCount,
                    selectedGraphFactCount:
                        selection.selectedGraphFactCount,
                    additionalGraphSourceCount:
                        selection.additionalGraphSourceCount,
                    omittedGraphFactCount:
                        selection.omittedGraphFactCount)))
    }

    private static func ragPassage(_ citation: AskCitation) -> RAGPassage {
        RAGPassage(
            segmentID: citation.segmentID,
            sourceSegmentIDs: citation.sourceSegmentIDs,
            meetingID: citation.meetingID,
            meetingTitle: citation.meetingTitle,
            timestamp: citation.timestamp,
            transcriptRevision: citation.transcriptRevision,
            text: citation.text)
    }
}

private extension AskMeetings {
    func answerProgressively(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        let updates = AskProgressiveUpdateGate(limit: limit)
        let evidenceMilestone = AskFirstEvidenceMilestone()
        let answerMilestone = AskFirstAnswerMilestone(trace: trace)
        do {
            let citations = try await retrieveProgressiveCitations(
                question: question,
                limit: limit,
                trace: trace,
                updates: updates,
                milestone: evidenceMilestone,
                receiver: onEvidence)
            guard !citations.isEmpty else {
                await updates.close()
                return AskMeetingAnswer(
                    question: question,
                    generatedText: nil,
                    citations: [],
                    generationOutcome: .notRequested)
            }
            let generation = try await generateTranscriptAnswer(
                question: question,
                citations: citations,
                onAnswer: { update in
                    guard !Task.isCancelled,
                          let update = await updates.admitAnswer(update),
                          !Task.isCancelled
                    else { return }
                    await answerMilestone.reachIfNeeded()
                    await onAnswer(update)
                },
                onTimeout: { await updates.stopAnswering() })
            return try await finalizeProgressiveAnswer(
                question: question,
                citations: citations,
                generation: generation,
                updates: updates,
                milestone: answerMilestone,
                receiver: onAnswer)
        } catch {
            await updates.close()
            throw error
        }
    }

    func retrieveProgressiveCitations(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        updates: AskProgressiveUpdateGate,
        milestone: AskFirstEvidenceMilestone,
        receiver: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        let retrieved = try await retrieval.retrieve(
            question: question,
            limit: limit,
            trace: trace,
            onEvidence: { update in
                guard !Task.isCancelled,
                      let update = await updates.admitEvidence(update),
                      !Task.isCancelled
                else { return }
                await milestone.reachIfNeeded(
                    for: update.citations,
                    trace: trace)
                await receiver(update)
            })
        try Task.checkCancellation()
        let finalEvidence = try await updates.finalizeEvidence(retrieved)
        if let update = finalEvidence.update {
            try Task.checkCancellation()
            await milestone.reachIfNeeded(
                for: update.citations,
                trace: trace)
            await receiver(update)
        }
        await milestone.reachIfNeeded(
            for: finalEvidence.citations,
            trace: trace)
        return finalEvidence.citations
    }

    func finalizeProgressiveAnswer(
        question: String,
        citations: [AskCitation],
        generation: AskGenerationResult,
        updates: AskProgressiveUpdateGate,
        milestone: AskFirstAnswerMilestone,
        receiver: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        try Task.checkCancellation()
        let finalAnswer = await updates.finalizeAnswer(generation.text)
        if let update = finalAnswer.update {
            try Task.checkCancellation()
            await milestone.reachIfNeeded()
            await receiver(update)
        }
        try Task.checkCancellation()
        await updates.close()
        let outcome = generation.outcome == .generated && finalAnswer.text == nil
            ? AskGenerationOutcome.failed
            : generation.outcome
        return AskMeetingAnswer(
            question: question,
            generatedText: finalAnswer.text,
            citations: citations,
            generationOutcome: outcome)
    }
}
