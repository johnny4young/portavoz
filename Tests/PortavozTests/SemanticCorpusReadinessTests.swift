import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class SemanticCorpusReadinessTests: XCTestCase {
    func testUnavailableAssetsReportUnsupportedWithoutPreparingRuntime() async throws {
        let store = try await seededStore()
        let runtime = ReadinessSemanticRuntime(assetsAvailable: false)
        let resolver = ResolveSemanticCorpusReadiness(
            store: store,
            runtime: runtime)

        let readiness = try await resolver.current()
        let preparationRequests = await runtime.preparationRequests

        XCTAssertEqual(readiness, .unsupported)
        XCTAssertFalse(readiness.canSearchPublishedVectors)
        XCTAssertEqual(preparationRequests, [])
    }

    func testCompleteCorpusReportsReadyDespiteStaleFailurePhase() async throws {
        let seeded = try await seededStore()
        let pending = try await seeded.segmentsNeedingEmbeddings()
        _ = try await seeded.storeEmbeddings(
            Dictionary(uniqueKeysWithValues: pending.map {
                ($0.id, [Float](arrayLiteral: 1, 0))
            }),
            for: pending)
        let state = SemanticCorpusMaintenanceState(phase: .failed)
        let resolver = ResolveSemanticCorpusReadiness(
            store: seeded,
            runtime: ReadinessSemanticRuntime(assetsAvailable: true),
            maintenanceState: state)

        let readiness = try await resolver.current()
        XCTAssertEqual(readiness, .ready)
    }

    func testPendingCorpusReflectsIdleBuildingAndFailedMaintenance() async throws {
        let store = try await seededStore()
        let state = SemanticCorpusMaintenanceState()
        let resolver = ResolveSemanticCorpusReadiness(
            store: store,
            runtime: ReadinessSemanticRuntime(assetsAvailable: true),
            maintenanceState: state)

        let idleReadiness = try await resolver.current()
        XCTAssertEqual(idleReadiness, .partial)
        state.transition(to: .building)
        let buildingReadiness = try await resolver.current()
        XCTAssertEqual(buildingReadiness, .building)
        state.transition(to: .failed)
        let failed = try await resolver.current()
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(failed.canSearchPublishedVectors)
    }

    func testLibraryReadsPublishedVectorsWithoutAdvancingPendingCorpus() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Read-only semantic Library",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let published = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "The launch schedule remains committed for Friday afternoon.",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        let pending = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "A separate passage remains pending for background maintenance.",
            startTime: 5,
            endTime: 9,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([published, pending])
        let candidates = try await store.segmentsNeedingEmbeddings()
        let publishedCandidate = try XCTUnwrap(candidates.first {
            $0.id == published.id
        })
        _ = try await store.storeEmbeddings(
            [published.id: [1, 0]],
            for: [publishedCandidate])
        let runtime = ReadinessSemanticRuntime(assetsAvailable: true)
        let library = LocalLibrarySemanticSearch(
            store: store,
            runtime: runtime)
        let pendingBefore = try await store.segmentsNeedingEmbeddings()

        let hits = try await library.search("release timing")

        let pendingAfter = try await store.segmentsNeedingEmbeddings()
        let preparationRequests = await runtime.preparationRequests
        XCTAssertEqual(hits.map(\.segmentID), [published.id])
        XCTAssertEqual(pendingAfter.map(\.id), pendingBefore.map(\.id))
        XCTAssertEqual(preparationRequests, [false])
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Semantic readiness fixture",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "This complete passage remains pending for semantic maintenance.",
                startTime: 0,
                endTime: 4,
                isFinal: true)
        ])
        return store
    }
}

private actor ReadinessSemanticRuntime: SemanticEmbeddingRuntimeClient {
    private let assetsAvailable: Bool
    private(set) var preparationRequests: [Bool] = []

    init(assetsAvailable: Bool) {
        self.assetsAvailable = assetsAvailable
    }

    var hasAvailableAssets: Bool {
        get async { assetsAvailable }
    }

    func prepare(allowAssetDownload: Bool) {
        preparationRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        preparationRequests.append(allowAssetDownload)
        return try await operation(ReadinessSemanticEmbedder())
    }
}

private struct ReadinessSemanticEmbedder: SemanticTextEmbedding {
    func vectors(for texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}
