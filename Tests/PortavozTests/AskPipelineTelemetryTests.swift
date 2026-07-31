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

    func testLocalAnswerEmitsEveryImplementedStageInExecutionOrder() async throws {
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
        let startedStages = recorder.events.compactMap { event -> AskPipelineStage? in
            guard case .stageStarted(let span) = event else { return nil }
            return span.stage
        }
        XCTAssertEqual(startedStages, AskPipelineStage.allCases)
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

        XCTAssertEqual(answer.generatedText, "  \n")
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
    func expand(_ question: String) -> [String] {
        [question]
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

    func search(query _: String, limit _: Int) -> [AskSearchResult] {
        []
    }

    func retrieve(question _: String, limit _: Int) -> [AskCitation] {
        [AskCitation(
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

private struct FixedSemanticEmbedding: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
