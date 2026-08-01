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
