import Foundation
import PortavozCore
import XCTest

@testable import StorageKit
@testable import portavoz_app

final class SpotlightIndexerTests: XCTestCase {
    func testBurstRequestsCoalesceIntoOneProtectedReplacement() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy()
        let sleeper = SuspendedSpotlightSleep()
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            debounce: .milliseconds(250),
            retryDelays: [],
            sleep: { _ in try await sleeper.sleep() })

        await indexer.requestReindex()
        await sleeper.waitUntilSuspended()
        await indexer.requestReindex()
        await indexer.requestReindex()
        await sleeper.release()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 1)
        XCTAssertEqual(snapshot.documentCounts, [1])
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testMatchingClientStateSkipsReplacementButRetriesLegacyCleanup() async throws {
        let store = try await seededStore()
        let documents = try await store.spotlightDocuments()
        let backend = SpotlightBackendSpy(
            clientState: SpotlightIndexer.clientState(for: documents))
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            debounce: .zero,
            retryDelays: [],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 0)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testTransientFailureRetriesWithoutLosingPendingWork() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy(replacementFailures: 2)
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            debounce: .zero,
            retryDelays: [.zero, .zero],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 3)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let status = await indexer.status
        XCTAssertEqual(status, .idle)
    }

    func testExhaustedRetriesRemainVisibleAndANewRequestCanRecover() async throws {
        let store = try await seededStore()
        let backend = SpotlightBackendSpy(replacementFailures: 2)
        let indexer = SpotlightIndexer(
            store: store,
            enabled: true,
            backend: backend,
            debounce: .zero,
            retryDelays: [.zero],
            sleep: { _ in })

        await indexer.requestReindex()
        await indexer.waitUntilIdle()
        let failedStatus = await indexer.status
        XCTAssertEqual(failedStatus, .failed(attempts: 2))

        await indexer.requestReindex()
        await indexer.waitUntilIdle()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.replacements, 3)
        XCTAssertEqual(snapshot.legacyRemovals, 1)
        let recoveredStatus = await indexer.status
        XCTAssertEqual(recoveredStatus, .idle)
    }

    private func seededStore() async throws -> MeetingStore {
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(
            title: "Searchable",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        return store
    }
}

private actor SpotlightBackendSpy: SpotlightIndexBackend {
    struct Snapshot: Sendable {
        let replacements: Int
        let documentCounts: [Int]
        let legacyRemovals: Int
    }

    private var clientState: Data?
    private var remainingReplacementFailures: Int
    private var replacementCount = 0
    private var documentCounts: [Int] = []
    private var legacyRemovalCount = 0

    init(clientState: Data? = nil, replacementFailures: Int = 0) {
        self.clientState = clientState
        remainingReplacementFailures = replacementFailures
    }

    func lastClientState() async throws -> Data? { clientState }

    func replace(_ documents: [SpotlightDocument], clientState: Data) async throws {
        replacementCount += 1
        documentCounts.append(documents.count)
        if remainingReplacementFailures > 0 {
            remainingReplacementFailures -= 1
            throw SpotlightBackendSpyError.injectedFailure
        }
        self.clientState = clientState
    }

    func removeLegacyDefaultItems() async throws {
        legacyRemovalCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            replacements: replacementCount,
            documentCounts: documentCounts,
            legacyRemovals: legacyRemovalCount)
    }
}

private actor SuspendedSpotlightSleep {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep() async throws {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        while continuations.isEmpty { await Task.yield() }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum SpotlightBackendSpyError: Error {
    case injectedFailure
}
