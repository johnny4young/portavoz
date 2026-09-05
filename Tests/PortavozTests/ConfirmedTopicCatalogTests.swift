import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class ConfirmedTopicCatalogTests: XCTestCase {
    func testLookupNormalizesWhitespaceAndRejectsUnboundedInput() throws {
        let lookup = try ConfirmedTopicCatalogLookup(
            matching: "  Diseño\t de   APIs  ",
            limit: 21)

        XCTAssertEqual(lookup.matching, "Diseño de APIs")
        XCTAssertEqual(lookup.limit, 21)
        XCTAssertThrowsError(
            try ConfirmedTopicCatalogLookup(limit: 0)) { error in
                XCTAssertEqual(error as? ConfirmedTopicCatalogLookupError, .invalidLimit)
            }
        XCTAssertThrowsError(
            try ConfirmedTopicCatalogLookup(
                matching: String(repeating: "a", count: 121))) { error in
                    XCTAssertEqual(
                        error as? ConfirmedTopicCatalogLookupError,
                        .queryTooLong)
                }
    }

    func testCatalogSearchIsBoundedAliasAwareAndReturnsExactLiveRoots() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await TopicContinuityTests.seedMeeting(
            store,
            texts: (0..<24).map { "Confirmed topic \($0)." })
        let rollout = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Atlas rollout",
            language: "en",
            origin: .manual))
        let spanishAlias = try await store.linkTopic(
            TopicContinuityTests.proposal(
                meeting: seeded.meeting,
                segment: seeded.segments[1],
                label: "Lanzamiento Atlas",
                language: "es",
                origin: .manual),
            to: rollout.topic.id)
        let security = try await store.createTopicAndLink(TopicContinuityTests.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[2],
            label: "Atlas security",
            language: "en",
            origin: .manual))
        for index in 3..<24 {
            _ = try await store.createTopicAndLink(TopicContinuityTests.proposal(
                meeting: seeded.meeting,
                segment: seeded.segments[index],
                label: "Topic \(index)",
                language: "en",
                origin: .manual))
        }
        let loader = LoadConfirmedTopicCatalog(catalog: store)

        do {
            _ = try await store.confirmedTopics(
                matching: String(repeating: "a", count: 121),
                limit: 21)
            XCTFail("Storage must reject an oversized direct query")
        } catch {
            XCTAssertTrue(error is StorageError)
        }

        let byMergedAlias = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "lanzamiento", limit: 21))
        XCTAssertEqual(byMergedAlias.map(\.id), [rollout.topic.id])
        XCTAssertFalse(byMergedAlias.contains { $0.id == spanishAlias.observedTopic.id })

        let atlas = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "ÁTLAS", limit: 21))
        XCTAssertEqual(
            atlas.map(\.id),
            [rollout.topic.id, security.topic.id],
            "aliases resolve to distinct exact roots without duplicate rows")

        let literalPercent = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "%", limit: 21))
        let literalUnderscore = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "_", limit: 21))
        let literalEscape = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "\\", limit: 21))
        XCTAssertTrue(literalPercent.isEmpty)
        XCTAssertTrue(literalUnderscore.isEmpty)
        XCTAssertTrue(literalEscape.isEmpty)

        let bounded = try await loader.execute(
            ConfirmedTopicCatalogLookup(limit: 21))
        XCTAssertEqual(bounded.count, 21)
        XCTAssertTrue(bounded.allSatisfy { $0.mergedIntoTopicID == nil })
        XCTAssertEqual(Set(bounded.map(\.id)).count, bounded.count)

        let directBlank = try await store.confirmedTopics(
            matching: "  \t ",
            limit: 21)
        XCTAssertEqual(
            directBlank.map(\.id),
            bounded.map(\.id),
            "blank direct reads must keep the same bounded live-root contract")
    }

    func testLoaderDelegatesOneNormalizedBoundedRead() async throws {
        let topic = Topic(preferredLabel: "Rollout")
        let catalog = ConfirmedTopicCatalogSpy(result: [topic])
        let loader = LoadConfirmedTopicCatalog(catalog: catalog)

        let result = try await loader.execute(
            ConfirmedTopicCatalogLookup(matching: "  rollout  ", limit: 7))

        XCTAssertEqual(result, [topic])
        let requests = await catalog.requests
        XCTAssertEqual(requests, [.init(matching: "rollout", limit: 7)])
    }
}

private actor ConfirmedTopicCatalogSpy: ConfirmedTopicCatalogReading {
    struct Request: Equatable {
        let matching: String?
        let limit: Int
    }

    private(set) var requests: [Request] = []
    private let result: [Topic]

    init(result: [Topic]) {
        self.result = result
    }

    func confirmedTopics(
        matching query: String?,
        limit: Int
    ) async throws -> [Topic] {
        requests.append(Request(matching: query, limit: limit))
        return result
    }
}
