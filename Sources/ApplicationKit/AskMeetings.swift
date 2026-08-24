import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit

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
    case search(query: String, source: AskSourceScope, limit: Int)
    case evidence(question: String, source: AskSourceScope, limit: Int)
    case answer(question: String, source: AskSourceScope, limit: Int)
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
        case .search(let query, let source, let limit):
            return .search(try await search(query, source: source, limit: limit))
        case .evidence(let question, let source, let limit):
            return .evidence(try await evidence(
                question,
                source: source,
                limit: limit))
        case .answer(let question, let source, let limit):
            return .answer(try await answer(
                question,
                source: source,
                limit: limit))
        }
    }

    public func search(
        _ query: String,
        source: AskSourceScope,
        limit: Int = 6
    ) async throws -> [AskSearchResult] {
        try Self.validateLocalSource(source)
        guard let query = try Self.validatedRequest(query, limit: limit) else {
            return []
        }
        return try await telemetry.measure(.search) { trace in
            let results = try await retrieval.search(
                query: query,
                source: source,
                limit: limit,
                trace: trace)
            try Self.validate(results, for: source)
            if !results.isEmpty {
                trace.reach(.firstEvidence)
            }
            return results
        }
    }

    public func evidence(
        _ question: String,
        source: AskSourceScope,
        limit: Int = 6
    ) async throws -> [AskCitation] {
        try Self.validateLocalSource(source)
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return []
        }
        return try await telemetry.measure(.evidence) { trace in
            let citations = try await retrieval.retrieve(
                question: question,
                source: source,
                limit: limit,
                trace: trace,
                onEvidence: { _ in })
            try Self.validate(citations, for: source)
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
        source: AskSourceScope,
        limit: Int = 6,
        graphQuery: AskGraphFactQuery? = nil,
        graphFilter: AskGraphFactFilterRequest? = nil
    ) async throws -> AskEvidenceBundle {
        try Self.validateLocalSource(source)
        if graphQuery != nil || graphFilter != nil {
            try Self.validateGraphSource(source)
        }
        guard let question = try Self.validatedRequest(question, limit: limit) else {
            return AskEvidenceBundle(
                transcriptCitations: [],
                graphFacts: .notRequested)
        }

        return try await telemetry.measure(.evidence) { trace in
            try await retrieveEvidenceBundle(
                question: question,
                source: source,
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
        source: AskSourceScope,
        limit: Int = 6,
        graphQuery: AskGraphFactQuery,
        graphFilter: AskGraphFactFilterRequest? = nil
    ) async throws -> AskEvidenceBundleAnswer {
        try Self.validateLocalSource(source)
        try Self.validateGraphSource(source)
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
                source: source,
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
        source: AskSourceScope,
        limit: Int = 6
    ) async throws -> AskMeetingAnswer {
        try await answer(
            question,
            source: source,
            limit: limit,
            onEvidence: { _ in })
    }

    public func answer(
        _ question: String,
        source: AskSourceScope,
        limit: Int = 6,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        try await answer(
            question,
            source: source,
            limit: limit,
            onEvidence: onEvidence,
            onAnswer: { _ in })
    }

    public func answer(
        _ question: String,
        source: AskSourceScope,
        limit: Int = 6,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        try Self.validateLocalSource(source)
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
                source: source,
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
        source: AskSourceScope,
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
            source: source,
            limit: limit,
            trace: trace,
            onEvidence: { _ in })
        try Self.validate(citations, for: source)
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

    private static func validateLocalSource(
        _ source: AskSourceScope
    ) throws {
        switch source {
        case .library, .meeting:
            return
        case .notes:
            throw AskSourcePolicyError.notesRequireTypedAdapter
        case .web:
            throw AskSourcePolicyError.webUnavailable
        }
    }

    private static func validateGraphSource(
        _ source: AskSourceScope
    ) throws {
        guard source == .library else {
            throw AskSourcePolicyError.graphFactsRequireLibrary
        }
    }

    private static func validate(
        _ results: [AskSearchResult],
        for source: AskSourceScope
    ) throws {
        guard case .meeting(let meetingID) = source else { return }
        guard results.allSatisfy({ $0.meetingID == meetingID }) else {
            throw AskSourcePolicyError.sourceEvidenceMismatch
        }
    }

    private static func validate(
        _ citations: [AskCitation],
        for source: AskSourceScope
    ) throws {
        guard case .meeting(let meetingID) = source else { return }
        guard citations.allSatisfy({ $0.meetingID == meetingID }) else {
            throw AskSourcePolicyError.sourceEvidenceMismatch
        }
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

private struct AskProgressiveEvidenceContext {
    let trace: AskPipelineTrace
    let updates: AskProgressiveUpdateGate
    let milestone: AskFirstEvidenceMilestone
    let receiver: AskEvidenceReceiver
}

private extension AskMeetings {
    func answerProgressively(
        question: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        let updates = AskProgressiveUpdateGate(limit: limit, source: source)
        let evidenceMilestone = AskFirstEvidenceMilestone()
        let answerMilestone = AskFirstAnswerMilestone(trace: trace)
        let evidenceContext = AskProgressiveEvidenceContext(
            trace: trace,
            updates: updates,
            milestone: evidenceMilestone,
            receiver: onEvidence)
        do {
            let citations = try await retrieveProgressiveCitations(
                question: question,
                source: source,
                limit: limit,
                context: evidenceContext)
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
        source: AskSourceScope,
        limit: Int,
        context: AskProgressiveEvidenceContext
    ) async throws -> [AskCitation] {
        let retrieved = try await retrieval.retrieve(
            question: question,
            source: source,
            limit: limit,
            trace: context.trace,
            onEvidence: { update in
                guard !Task.isCancelled,
                      let update = await context.updates.admitEvidence(update),
                      !Task.isCancelled
                else { return }
                await context.milestone.reachIfNeeded(
                    for: update.citations,
                    trace: context.trace)
                await context.receiver(update)
            })
        try Task.checkCancellation()
        try Self.validate(retrieved, for: source)
        let finalEvidence = try await context.updates.finalizeEvidence(retrieved)
        if let update = finalEvidence.update {
            try Task.checkCancellation()
            await context.milestone.reachIfNeeded(
                for: update.citations,
                trace: context.trace)
            await context.receiver(update)
        }
        await context.milestone.reachIfNeeded(
            for: finalEvidence.citations,
            trace: context.trace)
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
