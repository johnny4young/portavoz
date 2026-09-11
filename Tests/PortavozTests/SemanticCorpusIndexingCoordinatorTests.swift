import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class SemanticCorpusIndexingCoordinatorTests: XCTestCase {
    func testConcurrentBoundedRequestCoalescesWithoutDuplicatingEmbeddings() async throws {
        let store = try await seededStore(count: 3)
        let embedder = ControllableSemanticEmbedder()
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))

        let first = Task {
            try await coordinator.nextBatch(
                using: embedder,
                limit: 2)
        }
        await embedder.waitForCallCount(1)

        let coalesced = try await coordinator.nextBatch(
            using: DeterministicCoordinatorEmbedder(),
            limit: 2)

        XCTAssertEqual(coalesced, .empty)
        await embedder.releaseCall(1)
        let firstResult = try await first.value
        XCTAssertEqual(
            firstResult,
            SemanticCorpusIndexingResult(
                embeddedSegments: 2,
                excludedSegments: 0))
        let callCount = await embedder.callCount
        XCTAssertEqual(callCount, 1)
        let remaining = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(remaining.count, 1)
    }

    func testCompleteDemandWaitsForBoundedFlightThenDrainsDurableRemainder() async throws {
        let store = try await seededStore(count: 5)
        let embedder = ControllableSemanticEmbedder()
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))

        let bounded = Task {
            try await coordinator.nextBatch(
                using: embedder,
                limit: 2)
        }
        await embedder.waitForCallCount(1)
        let complete = Task {
            try await coordinator.all(
                using: embedder,
                batchSize: 2)
        }

        let firstCoalesced = try await coordinator.nextBatch(
            using: DeterministicCoordinatorEmbedder(),
            limit: 2)
        XCTAssertEqual(firstCoalesced, .empty)

        await embedder.releaseCall(1)
        let boundedResult = try await bounded.value
        XCTAssertEqual(boundedResult.embeddedSegments, 2)
        await embedder.waitForCallCount(2)

        let secondCoalesced = try await coordinator.nextBatch(
            using: DeterministicCoordinatorEmbedder(),
            limit: 2)
        XCTAssertEqual(secondCoalesced, .empty)

        await embedder.releaseCall(2)
        await embedder.waitForCallCount(3)
        await embedder.releaseCall(3)

        let completeResult = try await complete.value
        XCTAssertEqual(
            completeResult,
            SemanticCorpusIndexingResult(
                embeddedSegments: 5,
                excludedSegments: 0))
        let callCount = await embedder.callCount
        XCTAssertEqual(callCount, 3)
        let remaining = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCancellingOnlyWaiterStopsBeforePersistenceAndAllowsLaterWork() async throws {
        let store = try await seededStore(count: 2)
        let embedder = ControllableSemanticEmbedder()
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))

        let task = Task {
            try await coordinator.nextBatch(
                using: embedder,
                limit: 2)
        }
        await embedder.waitForCallCount(1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledRemaining = try await store.segmentsNeedingEmbeddings()
        XCTAssertEqual(cancelledRemaining.count, 2)
        let retry = try await coordinator.nextBatch(
            using: DeterministicCoordinatorEmbedder(),
            limit: 2)
        XCTAssertEqual(retry.embeddedSegments, 2)
        let finalRemaining = try await store.segmentsNeedingEmbeddings()
        XCTAssertTrue(finalRemaining.isEmpty)
    }

    private func seededStore(count: Int) async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Semantic coordination fixture",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        try await store.save((0..<count).map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Complete semantic passage \(index) with durable local evidence.",
                startTime: TimeInterval(index * 5),
                endTime: TimeInterval(index * 5 + 4),
                isFinal: true)
        })
        return store
    }
}

private actor DeterministicCoordinatorEmbedder: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private actor ControllableSemanticEmbedder: SemanticTextEmbedding {
    private struct Pending {
        let texts: [String]
        let continuation: CheckedContinuation<[[Float]], Error>
    }

    private(set) var callCount = 0
    private var pending: [Int: Pending] = [:]
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func vectors(for texts: [String]) async throws -> [[Float]] {
        callCount += 1
        let call = callCount
        resumeSatisfiedWaiters()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[call] = Pending(
                    texts: texts,
                    continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelCall(call)
            }
        }
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expected, continuation))
        }
    }

    func releaseCall(_ call: Int) {
        guard let pending = pending.removeValue(forKey: call) else { return }
        pending.continuation.resume(
            returning: pending.texts.map { _ in [1, 0] })
    }

    private func cancelCall(_ call: Int) {
        pending.removeValue(forKey: call)?.continuation.resume(
            throwing: CancellationError())
    }

    private func resumeSatisfiedWaiters() {
        let ready = callCountWaiters.filter { $0.0 <= callCount }
        callCountWaiters.removeAll { $0.0 <= callCount }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}
