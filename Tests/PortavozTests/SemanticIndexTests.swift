import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class SemanticIndexTests: XCTestCase {
    func testAccelerateExactControlMatchesCurrentStoreRanking() async throws {
        let fixture = try await Self.fixture()
        let query: [Float] = [0.9, 0.1]
        let expected = try await fixture.store.searchSemantic(
            query,
            profile: fixture.profile,
            limit: 2)
        let index = AccelerateExactSemanticIndex(store: fixture.store)

        let actual = try await index.search(
            query,
            profile: fixture.profile,
            limit: 2)

        XCTAssertEqual(actual.map(\.segmentID), expected.map(\.segmentID))
        XCTAssertEqual(actual.map(\.transcriptRevision), expected.map(\.transcriptRevision))
    }

    func testAskUsesInjectedSemanticIndexForPublishedEvidence() async throws {
        let fixture = try await Self.fixture()
        let storedHits = try await fixture.store.search("launch")
        let hit = try XCTUnwrap(storedHits.first)
        let index = RecordingSemanticIndex(hits: [hit])
        let retrieval = LocalAskMeetingRetrieval(
            store: fixture.store,
            queryExpander: NoAskQueryExpansion(),
            runtime: SemanticIndexRuntime(profile: fixture.profile),
            semanticIndex: index)

        let citations = try await retrieval.retrieve(
            question: "opaque wording",
            limit: 6)
        let requests = await index.requests

        XCTAssertEqual(citations.map(\.segmentID), [hit.segmentID])
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.query == [1, 0] })
        XCTAssertTrue(requests.allSatisfy { $0.profile == fixture.profile })
        XCTAssertTrue(requests.allSatisfy { $0.limit == 12 })
    }

    func testLibraryUsesInjectedSemanticIndexWithoutChangingItsLimit() async throws {
        let fixture = try await Self.fixture()
        let storedHits = try await fixture.store.search("launch")
        let hit = try XCTUnwrap(storedHits.first)
        let index = RecordingSemanticIndex(hits: [hit])
        let search = LocalLibrarySemanticSearch(
            store: fixture.store,
            runtime: SemanticIndexRuntime(profile: fixture.profile),
            semanticIndex: index)

        let hits = try await search.search("project timing", limit: 7)
        let requests = await index.requests

        XCTAssertEqual(hits.map(\.segmentID), [hit.segmentID])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.query, [1, 0])
        XCTAssertEqual(requests.first?.profile, fixture.profile)
        XCTAssertEqual(requests.first?.limit, 7)
    }

    func testShadowReturnsControlBeforeCandidateAndEmitsAggregateAgreement() async throws {
        let fixture = try await Self.fixture()
        let storedControlHits = try await fixture.store.search("launch")
        let storedCandidateHits = try await fixture.store.search("archive")
        let controlHit = try XCTUnwrap(storedControlHits.first)
        let candidateHit = try XCTUnwrap(storedCandidateHits.first)
        let control = RecordingSemanticIndex(hits: [controlHit])
        let candidate = RecordingSemanticIndex(hits: [candidateHit])
        let operations = SemanticIndexShadowOperationQueue()
        let events = SemanticIndexShadowEventRecorder()
        let index = ShadowComparingSemanticIndex(
            control: control,
            candidate: candidate,
            candidateAdapter: .sqliteVecExact,
            telemetry: events.telemetry,
            executor: operations.executor)

        let hits = try await index.search(
            [1, 0],
            profile: fixture.profile,
            limit: 4)

        XCTAssertEqual(hits.map(\.segmentID), [controlHit.segmentID])
        let requestsBeforeShadow = await candidate.requests
        XCTAssertEqual(requestsBeforeShadow.count, 0)
        XCTAssertEqual(events.values.count, 0)
        XCTAssertEqual(operations.count, 1)

        await operations.runNext()

        let requestsAfterShadow = await candidate.requests
        XCTAssertEqual(requestsAfterShadow.first?.query, [1, 0])
        XCTAssertEqual(events.values.count, 1)
        let event = try XCTUnwrap(events.values.first)
        XCTAssertEqual(event.candidate, .sqliteVecExact)
        XCTAssertEqual(event.outcome, .completed)
        XCTAssertEqual(event.queryDimension, 2)
        XCTAssertEqual(event.requestedLimit, 4)
        XCTAssertEqual(event.controlResultCount, 1)
        XCTAssertEqual(event.candidateResultCount, 1)
        XCTAssertEqual(event.overlapCount, 0)
        XCTAssertEqual(event.sameRankCount, 0)
        XCTAssertEqual(event.topHitAgreement, false)
    }

    func testShadowCandidateFailureCannotReplaceOrFailControl() async throws {
        let fixture = try await Self.fixture()
        let storedControlHits = try await fixture.store.search("launch")
        let controlHit = try XCTUnwrap(storedControlHits.first)
        let operations = SemanticIndexShadowOperationQueue()
        let events = SemanticIndexShadowEventRecorder()
        let index = ShadowComparingSemanticIndex(
            control: RecordingSemanticIndex(hits: [controlHit]),
            candidate: FailingSemanticIndex(),
            candidateAdapter: .coreSpotlightSemantic,
            telemetry: events.telemetry,
            executor: operations.executor)

        let hits = try await index.search(
            [1, 0],
            profile: fixture.profile,
            limit: 3)
        await operations.runNext()

        XCTAssertEqual(hits.map(\.segmentID), [controlHit.segmentID])
        let event = try XCTUnwrap(events.values.first)
        XCTAssertEqual(event.outcome, .failed)
        XCTAssertEqual(event.controlResultCount, 1)
        XCTAssertNil(event.candidateResultCount)
        XCTAssertNil(event.overlapCount)
        XCTAssertNil(event.sameRankCount)
        XCTAssertNil(event.topHitAgreement)
    }

    func testShadowDoesNotScheduleCandidateWhenControlFails() async throws {
        let fixture = try await Self.fixture()
        let operations = SemanticIndexShadowOperationQueue()
        let events = SemanticIndexShadowEventRecorder()
        let candidate = RecordingSemanticIndex(hits: [])
        let index = ShadowComparingSemanticIndex(
            control: FailingSemanticIndex(),
            candidate: candidate,
            candidateAdapter: .usearchHNSW,
            telemetry: events.telemetry,
            executor: operations.executor)

        do {
            _ = try await index.search(
                [1, 0],
                profile: fixture.profile,
                limit: 3)
            XCTFail("a failed exact control must remain authoritative")
        } catch SemanticIndexShadowTestError.unavailable {
            // Expected: there is no control result against which to compare.
        }

        let candidateRequests = await candidate.requests
        XCTAssertEqual(candidateRequests.count, 0)
        XCTAssertEqual(operations.count, 0)
        XCTAssertEqual(events.values.count, 0)
    }

    private static func fixture() async throws -> (
        store: MeetingStore,
        profile: SemanticEmbeddingProfile
    ) {
        let store = try MeetingStore.inMemory()
        let profile = semanticTestProfile()
        let meeting = Meeting(
            title: "Semantic index port",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let first = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "The launch project remains scheduled for Friday afternoon.",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        let second = TranscriptSegment(
            meetingID: meeting.id,
            channel: .system,
            text: "The unrelated archive note remains available for review.",
            startTime: 5,
            endTime: 9,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([first, second])
        let candidates = try await store.segmentsNeedingEmbeddings()
        let vectors = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (candidate.id, candidate.id == first.id ? [Float](arrayLiteral: 1, 0) : [0, 1])
        })
        _ = try await store.storeEmbeddings(
            vectors,
            for: candidates,
            profile: profile)
        return (store, profile)
    }
}

private actor RecordingSemanticIndex: SemanticIndexSearching {
    struct Request: Equatable, Sendable {
        let query: [Float]
        let profile: SemanticEmbeddingProfile
        let limit: Int
    }

    private let hits: [SearchHit]
    private(set) var requests: [Request] = []

    init(hits: [SearchHit]) {
        self.hits = hits
    }

    func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) -> [SearchHit] {
        requests.append(Request(
            query: query,
            profile: profile,
            limit: limit))
        return Array(hits.prefix(limit))
    }
}

private actor SemanticIndexRuntime: SemanticEmbeddingRuntimeClient {
    let profile: SemanticEmbeddingProfile

    init(profile: SemanticEmbeddingProfile) {
        self.profile = profile
    }

    var hasAvailableAssets: Bool { true }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? {
        profile
    }

    func prepare(allowAssetDownload: Bool) {}

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        try await operation(SemanticIndexEmbedder(profile: profile))
    }
}

private struct SemanticIndexEmbedder: SemanticTextEmbedding {
    let profile: SemanticEmbeddingProfile

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile {
        profile
    }

    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private struct NoAskQueryExpansion: AskQueryExpanding {
    func expand(_ question: String) -> [String] { [] }
}

private struct FailingSemanticIndex: SemanticIndexSearching {
    func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit] {
        throw SemanticIndexShadowTestError.unavailable
    }
}

private enum SemanticIndexShadowTestError: Error {
    case unavailable
}

private final class SemanticIndexShadowOperationQueue: @unchecked Sendable {
    private typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private var operations: [Operation] = []

    var executor: SemanticIndexShadowExecutor {
        SemanticIndexShadowExecutor { [weak self] operation in
            self?.append(operation)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations.count
    }

    func runNext() async {
        let operation = takeNext()
        await operation?()
    }

    private func takeNext() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        return operations.isEmpty ? nil : operations.removeFirst()
    }

    private func append(_ operation: @escaping Operation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }
}

private final class SemanticIndexShadowEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SemanticIndexShadowEvent] = []

    var telemetry: SemanticIndexShadowTelemetry {
        SemanticIndexShadowTelemetry { [weak self] event in
            self?.record(event)
        }
    }

    var values: [SemanticIndexShadowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ event: SemanticIndexShadowEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}
