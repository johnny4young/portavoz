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

    func testPolicyPauseAtAdmissionLeavesTheDurableCursorUntouched() async throws {
        let (store, _) = try await seededStore(texts: [
            "First semantic passage must remain pending during active capture.",
            "Second semantic passage must remain pending during active capture.",
        ])
        let embedder = CountingSemanticEmbedder()
        let operation = IndexSemanticCorpus(
            store: store,
            maintenanceGate: DurableMaintenanceGate { _, _ in .pause })

        let result = try await operation.all(
            using: embedder,
            batchSize: 1)
        let embedderCallCount = await embedder.callCount
        let remainingSegments = try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(result, .paused)
        XCTAssertEqual(embedderCallCount, 0)
        XCTAssertEqual(remainingSegments.count, 2)
    }

    func testCheckpointPauseCommitsOneBatchAndLaterPassResumesFromMissingRows() async throws {
        let (store, _) = try await seededStore(texts: [
            "First semantic passage belongs to the durable committed checkpoint.",
            "Second semantic passage belongs to the durable committed checkpoint.",
            "Third semantic passage remains owned by the database retry cursor.",
        ])
        let pausedOperation = IndexSemanticCorpus(
            store: store,
            maintenanceGate: DurableMaintenanceGate { _, phase in
                phase == .admission ? .proceed : .pause
            })

        let paused = try await pausedOperation.all(
            using: DeterministicSemanticEmbedder(),
            batchSize: 2)
        let remainingAfterPause =
            try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(
            paused,
            SemanticCorpusIndexingResult(
                embeddedSegments: 2,
                excludedSegments: 0,
                pausedByPolicy: true))
        XCTAssertEqual(remainingAfterPause.count, 1)

        let resumed = try await IndexSemanticCorpus(store: store).all(
            using: DeterministicSemanticEmbedder(),
            batchSize: 2)
        let remainingAfterResume =
            try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(
            resumed,
            SemanticCorpusIndexingResult(
                embeddedSegments: 1,
                excludedSegments: 0))
        XCTAssertTrue(remainingAfterResume.isEmpty)
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

    func testConcurrentTranscriptEditSkipsStaleVectorAndResumesFromCurrentRow() async throws {
        let (store, segments) = try await seededStore(texts: [
            "The initial semantic source will be corrected during embedding.",
        ])
        var correctedDraft = segments[0]
        correctedDraft.text = "The corrected semantic source remains on the durable cursor."
        let corrected = correctedDraft
        let operation = IndexSemanticCorpus(store: store)

        let stalePass = try await operation.nextBatch(
            using: MutatingSemanticEmbedder {
                try await store.save([corrected])
            },
            limit: 1)

        XCTAssertEqual(
            stalePass,
            SemanticCorpusIndexingResult(
                embeddedSegments: 0,
                excludedSegments: 0,
                skippedSegments: 1))
        let pendingAfterEdit = try await store.segmentsNeedingEmbeddings()
        let staleHits = try await store.searchSemantic([1, 0])
        XCTAssertEqual(pendingAfterEdit.map(\.text), [corrected.text])
        XCTAssertTrue(staleHits.isEmpty)

        let resumed = try await operation.nextBatch(
            using: DeterministicSemanticEmbedder(),
            limit: 1)

        let pendingAfterResume = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(resumed.embeddedSegments, 1)
        XCTAssertTrue(pendingAfterResume.isEmpty)
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

private actor CountingSemanticEmbedder: SemanticTextEmbedding {
    private(set) var callCount = 0

    func vectors(for texts: [String]) -> [[Float]] {
        callCount += 1
        return texts.map { _ in [1, 0] }
    }
}

private struct MutatingSemanticEmbedder: SemanticTextEmbedding {
    let mutation: @Sendable () async throws -> Void

    init(mutation: @escaping @Sendable () async throws -> Void) {
        self.mutation = mutation
    }

    func vectors(for texts: [String]) async throws -> [[Float]] {
        try await mutation()
        return texts.map { _ in [1, 0] }
    }
}
