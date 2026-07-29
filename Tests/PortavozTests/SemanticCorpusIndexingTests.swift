import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class SemanticCorpusIndexingTests: XCTestCase {
    func testCompleteIndexingDrainsBatchesExcludesMicroSegmentsAndEmitsTelemetry() async throws {
        let (store, segments) = try await seededStore(texts: [
            "Background indexing must yield while an active call is recording.",
            "Exact search remains available when semantic assets are unavailable.",
            "short",
        ])
        let recorder = ResourceWorkloadEventRecorder()
        let operation = IndexSemanticCorpus(
            store: store,
            telemetry: ResourceWorkloadTelemetry(receiver: recorder.receive))

        let result = try await operation.all(
            using: DeterministicSemanticEmbedder(),
            batchSize: 2)

        XCTAssertEqual(
            result,
            SemanticCorpusIndexingResult(
                embeddedSegments: 2,
                excludedSegments: 1))
        let remainingSegments = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(remainingSegments.isEmpty)
        let hits = try await store.searchSemantic([1, 0], limit: 4)
        XCTAssertEqual(Set(hits.map(\.segmentID)), Set(segments.prefix(2).map(\.id)))
        assertCompletedIndexingSpan(recorder.events)
    }

    func testNextBatchLeavesRemainingCorpusForLaterMaintenance() async throws {
        let (store, _) = try await seededStore(texts: [
            "First complete semantic passage for the bounded maintenance batch.",
            "Second complete semantic passage for the bounded maintenance batch.",
            "Third complete semantic passage remains for a later maintenance pass.",
        ])
        let operation = IndexSemanticCorpus(store: store)

        let result = try await operation.nextBatch(
            using: DeterministicSemanticEmbedder(),
            limit: 2)

        XCTAssertEqual(result.embeddedSegments, 2)
        XCTAssertEqual(result.excludedSegments, 0)
        let remainingSegments = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(remainingSegments.count, 1)
    }

    func testVectorCountMismatchFailsBeforePublishingEmbeddings() async throws {
        let (store, _) = try await seededStore(texts: [
            "This complete semantic passage requires exactly one returned vector.",
        ])
        let recorder = ResourceWorkloadEventRecorder()
        let operation = IndexSemanticCorpus(
            store: store,
            telemetry: ResourceWorkloadTelemetry(receiver: recorder.receive))

        do {
            _ = try await operation.all(
                using: WrongCountSemanticEmbedder())
            XCTFail("Expected vector-count mismatch")
        } catch {
            XCTAssertEqual(
                error as? SemanticCorpusIndexingError,
                .vectorCountMismatch(expected: 1, actual: 0))
        }

        let remainingSegments = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(remainingSegments.count, 1)
        guard case .finished(_, let outcome) = recorder.events.last else {
            return XCTFail("Expected terminal indexing telemetry")
        }
        XCTAssertEqual(outcome, .failed)
    }

    private func seededStore(
        texts: [String]
    ) async throws -> (MeetingStore, [TranscriptSegment]) {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Semantic indexing fixture",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: text,
                startTime: TimeInterval(index * 5),
                endTime: TimeInterval(index * 5 + 4),
                isFinal: true)
        }
        try await store.save(segments)
        return (store, segments)
    }

    private func assertCompletedIndexingSpan(
        _ events: [ResourceWorkloadEvent]
    ) {
        guard case .started(let started) = events.first,
              case .finished(let finished, let outcome) = events.last
        else {
            return XCTFail("Expected one matched indexing span")
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(started, finished)
        XCTAssertEqual(
            started.descriptor,
            ResourceWorkloadDescriptor(
                workloadClass: .maintenance,
                kind: .searchIndex,
                operation: .execute))
        XCTAssertEqual(outcome, .completed)
    }
}

private actor DeterministicSemanticEmbedder: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.enumerated().map { index, _ in
            index.isMultiple(of: 2) ? [1, 0] : [0, 1]
        }
    }
}

private actor WrongCountSemanticEmbedder: SemanticTextEmbedding {
    func vectors(for _: [String]) -> [[Float]] {
        []
    }
}
