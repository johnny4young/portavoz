import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class AskPipelineTelemetryTests: XCTestCase {
    func testTaxonomyIsClosedAndStable() {
        XCTAssertEqual(
            AskPipelineOperation.allCases.map(\.rawValue),
            ["search", "evidence", "answer"])
        XCTAssertEqual(
            AskPipelineStage.allCases.map(\.rawValue),
            [
                "corpusReadiness", "expansion", "lexicalQuery",
                "queryEmbedding", "semanticScan", "fusion",
                "citationFetch",
            ])
        XCTAssertEqual(
            AskPipelineMilestone.allCases.map(\.rawValue),
            ["firstEvidence", "firstToken"])
    }

    func testTraceEmitsMatchedStagesMilestonesAndCompletion() async throws {
        let recorder = AskPipelineEventRecorder()
        let telemetry = AskPipelineTelemetry(receiver: recorder.receive)

        let value = await telemetry.measure(.answer) { trace in
            let count = await trace.measure(.lexicalQuery) { 3 }
            trace.reach(.firstEvidence)
            trace.reach(.firstToken)
            return count
        }

        XCTAssertEqual(value, 3)
        let events = recorder.events
        guard case .started(let started) = try XCTUnwrap(events.first),
              case .stageStarted(let stageStarted) = events[1],
              case .stageFinished(let stageFinished, let stageOutcome) = events[2],
              case .reached(let evidenceTrace, let evidenceMilestone) = events[3],
              case .reached(let tokenTrace, let tokenMilestone) = events[4],
              case .finished(let finished, let outcome) = try XCTUnwrap(events.last)
        else {
            return XCTFail("Expected one complete Ask trace")
        }
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(started, finished)
        XCTAssertEqual(started.operation, .answer)
        XCTAssertEqual(stageStarted, stageFinished)
        XCTAssertEqual(stageStarted.trace, started)
        XCTAssertEqual(stageStarted.stage, .lexicalQuery)
        XCTAssertEqual(stageOutcome, .completed)
        XCTAssertEqual(evidenceTrace, started)
        XCTAssertEqual(evidenceMilestone, .firstEvidence)
        XCTAssertEqual(tokenTrace, started)
        XCTAssertEqual(tokenMilestone, .firstToken)
        XCTAssertEqual(outcome, .completed)
    }

    func testCancellationClosesStageAndTraceWithoutErrorPayload() async {
        let recorder = AskPipelineEventRecorder()
        let telemetry = AskPipelineTelemetry(receiver: recorder.receive)

        do {
            _ = try await telemetry.measure(.evidence) { trace in
                try await trace.measure(.semanticScan) {
                    throw CancellationError()
                }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        guard case .stageFinished(_, let stageOutcome) = recorder.events[2],
              case .finished(_, let traceOutcome) = recorder.events.last
        else {
            return XCTFail("Expected matched cancelled intervals")
        }
        XCTAssertEqual(stageOutcome, .cancelled)
        XCTAssertEqual(traceOutcome, .cancelled)
    }

    func testRetrievalFailureClosesTraceAsFailed() async {
        let recorder = AskPipelineEventRecorder()
        let useCase = AskMeetings(
            retrieval: FailingAskRetrieval(),
            answering: FixedAskAnswerer(),
            telemetry: AskPipelineTelemetry(receiver: recorder.receive))

        do {
            _ = try await useCase.evidence("status")
            XCTFail("Expected retrieval failure")
        } catch is AskPipelineTestError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.events.count, 2)
        guard case .started(let started) = recorder.events.first,
              case .finished(let finished, let outcome) = recorder.events.last
        else {
            return XCTFail("Expected one failed Ask trace")
        }
        XCTAssertEqual(started, finished)
        XCTAssertEqual(outcome, .failed)
    }

    func testInvalidRequestsDoNotCreateTraces() async throws {
        let recorder = AskPipelineEventRecorder()
        let useCase = AskMeetings(
            retrieval: FailingAskRetrieval(),
            answering: FixedAskAnswerer(),
            telemetry: AskPipelineTelemetry(receiver: recorder.receive))

        let searchResults = try await useCase.search(" \n")
        let evidence = try await useCase.evidence("status", limit: 0)
        let answer = try await useCase.answer("\t")

        XCTAssertEqual(searchResults, [])
        XCTAssertEqual(evidence, [])
        XCTAssertEqual(answer.question, "")
        XCTAssertEqual(answer.citations, [])
        XCTAssertNil(answer.generatedText)
        XCTAssertEqual(recorder.events, [])
    }

    func testLocalAnswerEmitsEveryImplementedStageWithProgressiveOrdering() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "budget rollout remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let pendingBefore = try await store.segmentsNeedingEmbeddings()

        let recorder = AskPipelineEventRecorder()
        let telemetry = AskPipelineTelemetry(receiver: recorder.receive)
        let useCase = AskMeetings(
            retrieval: LocalAskMeetingRetrieval(
                store: store,
                queryExpander: FixedAskQueryExpander(),
                runtime: FixedSemanticRuntime()),
            answering: FixedAskAnswerer(),
            telemetry: telemetry)

        let answer = try await useCase.answer("When is the budget rollout?")

        XCTAssertEqual(answer.citations.map(\.segmentID), [segment.id])
        XCTAssertEqual(answer.generatedText, "Friday.")
        let pendingAfter = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(
            pendingAfter.map(\.id),
            pendingBefore.map(\.id),
            "Ask must not publish corpus embeddings during a request")
        let startedStages = recorder.events.compactMap { event -> AskPipelineStage? in
            guard case .stageStarted(let span) = event else { return nil }
            return span.stage
        }
        XCTAssertEqual(startedStages.first, .expansion)
        XCTAssertEqual(startedStages.count, AskPipelineStage.allCases.count)
        XCTAssertEqual(Set(startedStages), Set(AskPipelineStage.allCases))
        let events = recorder.events
        let evidenceIndex = try XCTUnwrap(events.firstIndex { event in
            guard case .reached(_, .firstEvidence) = event else { return false }
            return true
        })
        let lexicalFinishedIndex = try XCTUnwrap(events.firstIndex { event in
            guard case .stageFinished(let span, .completed) = event else { return false }
            return span.stage == .lexicalQuery
        })
        let fusionStartedIndex = try XCTUnwrap(events.firstIndex { event in
            guard case .stageStarted(let span) = event else { return false }
            return span.stage == .fusion
        })
        XCTAssertGreaterThan(evidenceIndex, lexicalFinishedIndex)
        XCTAssertLessThan(evidenceIndex, fusionStartedIndex)
        XCTAssertEqual(
            recorder.events.compactMap { event -> AskPipelineMilestone? in
                guard case .reached(_, let milestone) = event else { return nil }
                return milestone
            },
            [.firstEvidence, .firstToken])
        guard case .finished(_, let outcome) = recorder.events.last else {
            return XCTFail("Expected a completed Ask trace")
        }
        XCTAssertEqual(outcome, .completed)
    }

    func testExactBilingualEvidenceSkipsGenerativeExpansion() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "El presupuesto se revisa el viernes",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let expander = CountingAskQueryExpander(expansion: ["budget", "apollo"])
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: expander,
            runtime: UnavailableSemanticRuntime())

        let citations = try await retrieval.retrieve(
            question: "budget",
            limit: 6)
        let expansionCalls = await expander.callCount

        XCTAssertEqual(citations.map(\.segmentID), [segment.id])
        XCTAssertEqual(expansionCalls, 0)
    }

    func testGenerativeExpansionRunsOnlyAfterDeterministicEvidenceIsEmpty() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "The Apollo launch remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let expander = CountingAskQueryExpander(
            expansion: ["frobnicate", "apollo"])
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: expander,
            runtime: UnavailableSemanticRuntime())

        let citations = try await retrieval.retrieve(
            question: "frobnicate",
            limit: 6)
        let expansionCalls = await expander.callCount

        XCTAssertEqual(citations.map(\.segmentID), [segment.id])
        XCTAssertEqual(expansionCalls, 1)
    }

    func testGenerativeExpansionCancellationCannotBecomeAnEmptyFallback() async throws {
        let store = try MeetingStore.inMemory()
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: CancelledAskQueryExpander(),
            runtime: UnavailableSemanticRuntime())

        do {
            _ = try await retrieval.retrieve(
                question: "missing evidence",
                limit: 6)
            XCTFail("cancelled expansion must cancel the complete retrieval")
        } catch is CancellationError {
            // Cancellation is terminal, not an ordinary empty expansion.
        }
    }

    func testLexicalEvidencePublishesWhileSemanticAugmentationIsStillRunning() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "budget rollout remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let gate = SemanticRuntimeGate()
        let updates = AskEvidenceUpdateRecorder()
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: FixedAskQueryExpander(),
            runtime: BlockingSemanticRuntime(gate: gate))

        let task = Task {
            try await AskPipelineTelemetry.disabled.measure(.answer) { trace in
                try await retrieval.retrieve(
                    question: "budget rollout",
                    limit: 6,
                    trace: trace,
                    onEvidence: { update in
                        await updates.receive(update)
                    })
            }
        }
        await gate.waitUntilEntered()
        await updates.waitForCount(1)
        let lexicalUpdates = await updates.values

        XCTAssertEqual(lexicalUpdates.first?.phase, .lexical)
        XCTAssertEqual(lexicalUpdates.first?.citations.map(\.segmentID), [segment.id])

        await gate.release()
        let citations = try await task.value
        let finalUpdates = await updates.values
        XCTAssertEqual(citations.map(\.segmentID), [segment.id])
        XCTAssertEqual(finalUpdates.last?.phase, .fused)
    }

    func testColdSemanticAssetsPreserveLexicalEvidenceWithoutPreparingRuntime() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "budget rollout remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: FixedAskQueryExpander(),
            runtime: UnavailableSemanticRuntime())

        let citations = try await retrieval.retrieve(
            question: "When is the budget rollout?",
            limit: 6)

        XCTAssertEqual(citations.map(\.segmentID), [segment.id])
        let pendingAfter = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(
            pendingAfter.map(\.id),
            [segment.id])
    }

    func testSemanticPreparationFailurePreservesLexicalEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "budget rollout remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: FixedAskQueryExpander(),
            runtime: FailingSemanticRuntime())

        let citations = try await retrieval.retrieve(
            question: "When is the budget rollout?",
            limit: 6)

        XCTAssertEqual(citations.map(\.segmentID), [segment.id])
    }

    func testSemanticCancellationStillCancelsRetrieval() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "budget rollout remains scheduled for Friday",
            startTime: 4,
            endTime: 8,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([segment])
        let retrieval = LocalAskMeetingRetrieval(
            store: store,
            queryExpander: FixedAskQueryExpander(),
            runtime: CancelledSemanticRuntime())

        do {
            _ = try await retrieval.retrieve(
                question: "When is the budget rollout?",
                limit: 6)
            XCTFail("Semantic cancellation must cancel Ask retrieval")
        } catch is CancellationError {
            // Expected: cancellation is never degraded to lexical success.
        }
    }

    func testAppAdapterObserverHasExplicitLifetime() async {
        let recorder = AskPipelineEventRecorder()
        let adapter = AppAskPipelineTelemetry.shared
        let observer = adapter.addObserver(recorder.receive)

        _ = await adapter.telemetry.measure(.search) { _ in 1 }
        adapter.removeObserver(observer)
        _ = await adapter.telemetry.measure(.search) { _ in 2 }

        XCTAssertEqual(recorder.events.count, 2)
        guard case .started(let started) = recorder.events.first,
              case .finished(let finished, let outcome) = recorder.events.last
        else {
            return XCTFail("Expected one observed app trace")
        }
        XCTAssertEqual(started, finished)
        XCTAssertEqual(outcome, .completed)
    }

    func testWhitespaceOnlyGenerationDoesNotClaimFirstToken() async throws {
        let meetingID = MeetingID()
        let recorder = AskPipelineEventRecorder()
        let useCase = AskMeetings(
            retrieval: FixedCitationRetrieval(meetingID: meetingID),
            answering: WhitespaceAskAnswerer(),
            telemetry: AskPipelineTelemetry(receiver: recorder.receive))

        let answer = try await useCase.answer("status")

        XCTAssertNil(answer.generatedText)
        XCTAssertEqual(answer.generationOutcome, .failed)
        XCTAssertEqual(
            recorder.events.compactMap { event -> AskPipelineMilestone? in
                guard case .reached(_, let milestone) = event else { return nil }
                return milestone
            },
            [.firstEvidence])
    }
}

private final class AskPipelineEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AskPipelineEvent] = []

    var events: [AskPipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: AskPipelineEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private struct FixedAskQueryExpander: AskQueryExpanding {
    func expand(_ question: String) throws -> [String] {
        [question]
    }
}

private struct CancelledAskQueryExpander: AskQueryExpanding {
    func expand(_: String) async throws -> [String] {
        throw CancellationError()
    }
}

private actor CountingAskQueryExpander: AskQueryExpanding {
    let expansion: [String]
    private(set) var callCount = 0

    init(expansion: [String]) {
        self.expansion = expansion
    }

    func expand(_ question: String) throws -> [String] {
        callCount += 1
        return expansion.isEmpty ? [question] : expansion
    }
}

private actor AskEvidenceUpdateRecorder {
    private(set) var values: [AskEvidenceUpdate] = []

    func receive(_ update: AskEvidenceUpdate) {
        values.append(update)
    }

    func waitForCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }
}

private actor SemanticRuntimeGate {
    private var didEnter = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        didEnter = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FixedAskAnswerer: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        "Friday."
    }
}

private enum AskPipelineTestError: Error {
    case unavailable
}

private struct FailingAskRetrieval: AskMeetingRetrieving {
    func search(query _: String, limit _: Int) async throws -> [AskSearchResult] {
        throw AskPipelineTestError.unavailable
    }

    func retrieve(question _: String, limit _: Int) async throws -> [AskCitation] {
        throw AskPipelineTestError.unavailable
    }
}

private struct WhitespaceAskAnswerer: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) -> String? {
        "  \n"
    }
}

private struct FixedCitationRetrieval: AskMeetingRetrieving {
    let meetingID: MeetingID
    private let segmentID = UUID()

    func search(query _: String, limit _: Int) -> [AskSearchResult] {
        []
    }

    func retrieve(question _: String, limit _: Int) -> [AskCitation] {
        [AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Planning",
            timestamp: 1,
            text: "Status is ready.")]
    }
}

private struct FixedSemanticRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { true } }

    func prepare(allowAssetDownload _: Bool) async throws {}

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        try await operation(FixedSemanticEmbedding())
    }
}

private struct BlockingSemanticRuntime: SemanticEmbeddingRuntimeClient {
    let gate: SemanticRuntimeGate

    var hasAvailableAssets: Bool { get async { true } }

    func prepare(allowAssetDownload _: Bool) async throws {}

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        await gate.wait()
        return try await operation(FixedSemanticEmbedding())
    }
}

private struct UnavailableSemanticRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { false } }

    func prepare(allowAssetDownload _: Bool) async throws {
        throw AskPipelineTestError.unavailable
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        // Retrieval must not call this when `hasAvailableAssets` is false.
        // Cancellation would escape the lexical fallback and fail the test.
        throw CancellationError()
    }
}

private struct FailingSemanticRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { true } }

    func prepare(allowAssetDownload _: Bool) async throws {
        throw AskPipelineTestError.unavailable
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        guard !allowAssetDownload else { throw CancellationError() }
        throw AskPipelineTestError.unavailable
    }
}

private struct CancelledSemanticRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { true } }

    func prepare(allowAssetDownload _: Bool) async throws {
        throw CancellationError()
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        throw CancellationError()
    }
}

private struct FixedSemanticEmbedding: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
