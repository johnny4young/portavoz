import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class ProcessSemanticCorpusMaintenanceTests: XCTestCase {
    func testOrdinaryFailureSchedulesOneRetryThenBecomesTerminal() async throws {
        let store = try await seededStore()
        let runtime = FailingMaintenanceRuntime()
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let first = ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: SemanticCorpusIndexingCoordinator(
                operation: IndexSemanticCorpus(store: store)),
            heartbeatInterval: .seconds(60),
            retryDelays: [10],
            now: { start })

        let retryable = try await first.execute(owner: "semantic-workflow-owner")
        let pendingJobs = try await store.derivedMaintenanceJobs(kind: .semanticCorpus)
        let exactHits = try await store.search("exact search")

        XCTAssertEqual(retryable.retryAt, start.addingTimeInterval(10))
        XCTAssertFalse(retryable.terminalFailure)
        XCTAssertEqual(pendingJobs.map(\.state), [.pending])
        XCTAssertEqual(pendingJobs.map(\.attempt), [1])
        XCTAssertEqual(exactHits.count, 1)

        let retryTime = start.addingTimeInterval(11)
        let second = ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: SemanticCorpusIndexingCoordinator(
                operation: IndexSemanticCorpus(store: store)),
            heartbeatInterval: .seconds(60),
            retryDelays: [10],
            now: { retryTime })
        let terminal = try await second.execute(owner: "semantic-workflow-owner")
        let failedJobs = try await store.derivedMaintenanceJobs(kind: .semanticCorpus)
        let preparationRequests = await runtime.preparationRequests

        XCTAssertNil(terminal.retryAt)
        XCTAssertTrue(terminal.terminalFailure)
        XCTAssertEqual(failedJobs.map(\.state), [.failed])
        XCTAssertEqual(failedJobs.map(\.attempt), [2])
        XCTAssertEqual(preparationRequests, [false, false])

        let afterRelaunch = ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: SemanticCorpusIndexingCoordinator(
                operation: IndexSemanticCorpus(store: store)),
            heartbeatInterval: .seconds(60),
            retryDelays: [10],
            now: { retryTime.addingTimeInterval(1) })
        let persistedTerminal = try await afterRelaunch.execute(
            owner: "semantic-workflow-relaunch-owner")
        let requestsAfterRelaunch = await runtime.preparationRequests

        XCTAssertTrue(persistedTerminal.terminalFailure)
        XCTAssertEqual(requestsAfterRelaunch, [false, false])
    }

    func testCapturePolicyDeniesAdmissionAndRuntimeBorrowing() async throws {
        let store = try await seededStore()
        let runtime = FailingMaintenanceRuntime()
        let workflow = ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: SemanticCorpusIndexingCoordinator(
                operation: IndexSemanticCorpus(store: store)),
            mayStart: { false })

        let result = try await workflow.execute(owner: "semantic-capture-owner")
        let jobs = try await store.derivedMaintenanceJobs(kind: .semanticCorpus)
        let assetChecks = await runtime.assetChecks

        XCTAssertEqual(result.indexing, .paused)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(assetChecks, 0)
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Semantic workflow failure",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Exact search remains available while semantic maintenance retries.",
                startTime: 0,
                endTime: 4,
                isFinal: true)
        ])
        return store
    }
}

private actor FailingMaintenanceRuntime: SemanticEmbeddingRuntimeClient {
    private(set) var assetChecks = 0
    private(set) var preparationRequests: [Bool] = []

    var hasAvailableAssets: Bool {
        get async {
            assetChecks += 1
            return true
        }
    }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? {
        semanticTestProfile()
    }

    func prepare(allowAssetDownload: Bool) {
        preparationRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        preparationRequests.append(allowAssetDownload)
        throw FailingMaintenanceRuntimeError.failed
    }
}

private enum FailingMaintenanceRuntimeError: Error {
    case failed
}
