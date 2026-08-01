import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest
@testable import portavoz_app

@MainActor
final class SemanticCorpusIndexingSupervisorTests: XCTestCase {
    func testBurstKicksSerializeOneDrainAndOneRerunWithoutPolling() async {
        let probe = SemanticDrainProbe()
        let supervisor = SemanticCorpusIndexingSupervisor(
            drain: probe.drain)

        supervisor.kick()
        await probe.waitForStartedCount(1)
        supervisor.kick()
        supervisor.kick()
        supervisor.kick()

        await probe.release(1)
        await probe.waitForStartedCount(2)
        await probe.release(2)
        await probe.waitForFinishedCount(2)
        for _ in 0..<20 { await Task.yield() }

        let snapshot = await probe.snapshot
        XCTAssertEqual(snapshot.started, 2)
        XCTAssertEqual(snapshot.finished, 2)
        XCTAssertEqual(snapshot.maximumConcurrent, 1)
    }

    func testDisabledSupervisorIgnoresProductionWakeSignals() async {
        let probe = SemanticDrainProbe()
        let supervisor = SemanticCorpusIndexingSupervisor(
            isEnabled: false,
            drain: probe.drain)

        supervisor.kick()
        for _ in 0..<20 { await Task.yield() }

        let snapshot = await probe.snapshot
        XCTAssertEqual(snapshot.started, 0)
    }

    func testSupervisorPublishesBuildingThenIdleMaintenancePhase() async {
        let probe = SemanticDrainProbe()
        let state = SemanticCorpusMaintenanceState()
        let supervisor = SemanticCorpusIndexingSupervisor(
            maintenanceState: state,
            drain: probe.drain)

        supervisor.kick()
        await probe.waitForStartedCount(1)
        XCTAssertEqual(state.current, .building)

        await probe.release(1)
        await probe.waitForFinishedCount(1)
        await waitUntil { state.current == .idle }

        XCTAssertEqual(state.current, .idle)
    }

    func testSupervisorPublishesFailureUntilTheNextKickRecovers() async {
        let probe = FailingThenSuccessfulSemanticDrainProbe()
        let state = SemanticCorpusMaintenanceState()
        let supervisor = SemanticCorpusIndexingSupervisor(
            maintenanceState: state,
            drain: probe.drain)

        supervisor.kick()
        await waitUntil { state.current == .failed }
        let failedStartedCount = await probe.startedCount
        XCTAssertEqual(failedStartedCount, 1)

        supervisor.kick()
        await waitUntil { await probe.startedCount == 2 }
        await waitUntil { state.current == .idle }

        XCTAssertEqual(state.current, .idle)
    }

    func testCancellationStillRunsQueuedRerun() async {
        let probe = CancelingSemanticDrainProbe()
        let supervisor = SemanticCorpusIndexingSupervisor(
            drain: probe.drain)

        supervisor.kick()
        await waitUntil { await probe.startedCount == 1 }
        supervisor.kick()
        await probe.releaseFirst()
        await waitUntil { await probe.startedCount == 2 }

        let startedCount = await probe.startedCount
        XCTAssertEqual(startedCount, 2)
    }

    func testBackgroundDrainUsesInstalledAssetsWithoutRequestingDownload() async throws {
        let store = try await seededStore()
        let captureState = AppResourceCaptureState()
        let runtime = BackgroundSemanticRuntime(assetsAvailable: true)
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))
        let indexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            captureState: captureState)

        let result = try await indexer.drain()
        let runtimeSnapshot = await runtime.snapshot
        let remaining = try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(result.embeddedSegments, 2)
        XCTAssertFalse(result.pausedByPolicy)
        XCTAssertEqual(runtimeSnapshot.assetChecks, 1)
        XCTAssertEqual(runtimeSnapshot.downloadRequests, [false])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testBackgroundDrainDoesNotBorrowRuntimeDuringCapture() async throws {
        let store = try await seededStore()
        let captureState = AppResourceCaptureState()
        captureState.update(.active)
        let runtime = BackgroundSemanticRuntime(assetsAvailable: true)
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))
        let indexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            captureState: captureState)

        let result = try await indexer.drain()
        let runtimeSnapshot = await runtime.snapshot
        let remaining = try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(result, .paused)
        XCTAssertEqual(runtimeSnapshot.assetChecks, 0)
        XCTAssertTrue(runtimeSnapshot.downloadRequests.isEmpty)
        XCTAssertEqual(remaining.count, 2)
    }

    func testBackgroundDrainSkipsRuntimeWhenDurableCursorIsComplete() async throws {
        let store = try MeetingStore.inMemory()
        let captureState = AppResourceCaptureState()
        let runtime = BackgroundSemanticRuntime(assetsAvailable: true)
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))
        let indexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            captureState: captureState)

        let result = try await indexer.drain()
        let runtimeSnapshot = await runtime.snapshot

        XCTAssertEqual(result, .empty)
        XCTAssertEqual(runtimeSnapshot.assetChecks, 0)
        XCTAssertTrue(runtimeSnapshot.downloadRequests.isEmpty)
    }

    func testBackgroundDrainLeavesCursorPendingWhenAssetsAreUnavailable() async throws {
        let store = try await seededStore()
        let captureState = AppResourceCaptureState()
        let runtime = BackgroundSemanticRuntime(assetsAvailable: false)
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(store: store))
        let indexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            captureState: captureState)

        let result = try await indexer.drain()
        let runtimeSnapshot = await runtime.snapshot
        let remaining = try await store.segmentsNeedingEmbeddings()

        XCTAssertEqual(result, .empty)
        XCTAssertEqual(runtimeSnapshot.assetChecks, 1)
        XCTAssertTrue(runtimeSnapshot.downloadRequests.isEmpty)
        XCTAssertEqual(remaining.count, 2)
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Background semantic fixture",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The durable semantic owner resumes this first complete passage.",
                startTime: 0,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The durable semantic owner resumes this second complete passage.",
                startTime: 5,
                endTime: 9,
                isFinal: true)
        ])
        return store
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for semantic maintenance state")
    }
}

private actor FailingThenSuccessfulSemanticDrainProbe {
    private(set) var startedCount = 0

    func drain() async throws -> SemanticCorpusIndexingResult {
        startedCount += 1
        if startedCount == 1 {
            throw SemanticDrainError.failed
        }
        return .empty
    }
}

private enum SemanticDrainError: Error {
    case failed
}

private actor CancelingSemanticDrainProbe {
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var startedCount = 0

    func drain() async throws -> SemanticCorpusIndexingResult {
        startedCount += 1
        guard startedCount == 1 else { return .empty }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
        throw CancellationError()
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor SemanticDrainProbe {
    struct Snapshot: Sendable {
        let started: Int
        let finished: Int
        let maximumConcurrent: Int
    }

    private var started = 0
    private var finished = 0
    private var active = 0
    private var maximumConcurrent = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishedWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    var snapshot: Snapshot {
        Snapshot(
            started: started,
            finished: finished,
            maximumConcurrent: maximumConcurrent)
    }

    func drain() async throws -> SemanticCorpusIndexingResult {
        started += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        let call = started
        resumeStartedWaiters()
        await withCheckedContinuation { continuation in
            pending[call] = continuation
        }
        active -= 1
        finished += 1
        resumeFinishedWaiters()
        return .empty
    }

    func release(_ call: Int) {
        pending.removeValue(forKey: call)?.resume()
    }

    func waitForStartedCount(_ expected: Int) async {
        guard started < expected else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((expected, continuation))
        }
    }

    func waitForFinishedCount(_ expected: Int) async {
        guard finished < expected else { return }
        await withCheckedContinuation { continuation in
            finishedWaiters.append((expected, continuation))
        }
    }

    private func resumeStartedWaiters() {
        let ready = startedWaiters.filter { $0.0 <= started }
        startedWaiters.removeAll { $0.0 <= started }
        ready.forEach { $0.1.resume() }
    }

    private func resumeFinishedWaiters() {
        let ready = finishedWaiters.filter { $0.0 <= finished }
        finishedWaiters.removeAll { $0.0 <= finished }
        ready.forEach { $0.1.resume() }
    }
}

private actor BackgroundSemanticRuntime: SemanticEmbeddingRuntimeClient {
    struct Snapshot: Sendable {
        let assetChecks: Int
        let downloadRequests: [Bool]
    }

    private let assetsAvailable: Bool
    private var assetChecks = 0
    private var downloadRequests: [Bool] = []

    init(assetsAvailable: Bool) {
        self.assetsAvailable = assetsAvailable
    }

    var hasAvailableAssets: Bool {
        get async {
            assetChecks += 1
            return assetsAvailable
        }
    }

    var snapshot: Snapshot {
        Snapshot(
            assetChecks: assetChecks,
            downloadRequests: downloadRequests)
    }

    func prepare(allowAssetDownload: Bool) {
        downloadRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        downloadRequests.append(allowAssetDownload)
        return try await operation(BackgroundSemanticEmbedder())
    }
}

private actor BackgroundSemanticEmbedder: SemanticTextEmbedding {
    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
