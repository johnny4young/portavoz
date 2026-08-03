import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class TopicFirstDiscussionQueryTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_787_100_000)

    func testUnreadyProjectionAndUnavailableTopicAbstain() async throws {
        let fixture = try await firstDiscussionFixture()

        let unready = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.rootTopicID))
        XCTAssertEqual(unready, .abstained(.projectionNotReady))

        _ = try await projectFirstDiscussionGraph(in: fixture.store)
        let unavailable = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: TopicID()))
        XCTAssertEqual(unavailable, .abstained(.topicUnavailable))
    }

    func testEarliestCurrentMentionReturnsOneTypedSourceBackedFact() async throws {
        let fixture = try await firstDiscussionFixture()
        _ = try await projectFirstDiscussionGraph(in: fixture.store)

        let result = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.rootTopicID))
        guard case .facts(let page) = result else {
            return XCTFail("Expected first-discussion fact, got \(result)")
        }
        let fact = try XCTUnwrap(page.facts.first)

        XCTAssertEqual(page.facts.count, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertGreaterThan(page.projectionGeneration, 0)
        XCTAssertEqual(fact.id, .topicEvidence(fixture.firstEvidenceID))
        XCTAssertEqual(fact.kind, .topicDiscussedInMeeting)
        XCTAssertEqual(fact.subject, .topic(fixture.rootTopicID))
        XCTAssertEqual(fact.object, .meeting(fixture.firstMeeting.id))
        XCTAssertEqual(fact.subjectText, "Atlas program")
        XCTAssertEqual(fact.objectText, fixture.firstMeeting.title)
        XCTAssertEqual(fact.status, .confirmed)
        XCTAssertEqual(fact.evidence.map(\.segmentID), [fixture.firstSegment.id])
        XCTAssertEqual(fact.evidence.map(\.text), [fixture.firstSegment.text])
        XCTAssertEqual(fact.navigation?.meetingID, fixture.firstMeeting.id)
        XCTAssertEqual(fact.navigation?.segmentID, fixture.firstSegment.id)
        XCTAssertEqual(fact.navigation?.timestamp, fixture.firstSegment.startTime)
    }

    func testMergedChildQueryResolvesFamilyRootAndEarliestEvidence() async throws {
        let fixture = try await firstDiscussionFixture()
        _ = try await projectFirstDiscussionGraph(in: fixture.store)

        let result = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.observedTopicID))
        guard case .facts(let page) = result else {
            return XCTFail("Expected merged-family fact, got \(result)")
        }

        XCTAssertEqual(page.facts.first?.subject, .topic(fixture.rootTopicID))
        XCTAssertEqual(
            page.facts.first?.id,
            .topicEvidence(fixture.firstEvidenceID))
    }

    func testStaleEarliestMentionCannotBeReplacedByLaterCurrentMention() async throws {
        let fixture = try await firstDiscussionFixture()
        var revisedMeeting = fixture.firstMeeting
        revisedMeeting.transcriptRevision += 1
        try await fixture.store.save(revisedMeeting)
        _ = try await projectFirstDiscussionGraph(in: fixture.store)

        let result = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.rootTopicID))

        XCTAssertEqual(result, .abstained(.staleEvidenceOnly))
    }

    func testUnavailableEarliestMentionCannotBeReplacedByLaterCurrentMention() async throws {
        let fixture = try await firstDiscussionFixture()
        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE segment SET deletedAt = ? WHERE id = ?",
                arguments: [Self.baseDate, fixture.firstSegment.id.uuidString])
        }
        _ = try await projectFirstDiscussionGraph(in: fixture.store)

        let result = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.rootTopicID))

        XCTAssertEqual(result, .abstained(.evidenceUnavailable))
    }

    func testReadyProjectionMissingExactEarliestEdgeFailsClosed() async throws {
        let fixture = try await firstDiscussionFixture()
        _ = try await projectFirstDiscussionGraph(in: fixture.store)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM meetingMemoryGraphMeetingTopic
                    WHERE topicID = ? AND meetingID = ?
                    """,
                arguments: [
                    fixture.rootTopicID.rawValue.uuidString,
                    fixture.firstMeeting.id.rawValue.uuidString,
                ])
        }

        let result = try await fixture.store.topicFirstDiscussion(
            TopicFirstDiscussionQuery(topicID: fixture.rootTopicID))

        XCTAssertEqual(result, .abstained(.projectionInconsistent))
    }

    func testApplicationUseCasePreservesTypedRepositoryResult() async throws {
        let topicID = TopicID()
        let expected = MeetingMemoryGraphQueryResult.abstained(.staleEvidenceOnly)
        let repository = FirstDiscussionRepositoryStub(result: expected)

        let result = try await LoadTopicFirstDiscussion(repository: repository)
            .execute(TopicFirstDiscussionQuery(topicID: topicID))

        XCTAssertEqual(result, expected)
        let received = await repository.receivedQuery
        XCTAssertEqual(
            received,
            TopicFirstDiscussionQuery(topicID: topicID))
    }

    private func firstDiscussionFixture() async throws -> FirstDiscussionFixture {
        let store = try MeetingStore.inMemory()
        let firstMeeting = Meeting(
            title: "Atlas introduction",
            startedAt: Self.baseDate)
        let laterMeeting = Meeting(
            title: "Atlas follow-up",
            startedAt: Self.baseDate.addingTimeInterval(86_400))
        let firstSegment = TranscriptSegment(
            meetingID: firstMeeting.id,
            channel: .system,
            text: "The team first introduced the Atlas program.",
            language: "en",
            startTime: 5,
            endTime: 9,
            isFinal: true)
        let laterSegment = TranscriptSegment(
            meetingID: laterMeeting.id,
            channel: .system,
            text: "El equipo retomó el programa Atlas.",
            language: "es",
            startTime: 3,
            endTime: 7,
            isFinal: true)
        try await store.save(firstMeeting)
        try await store.save(laterMeeting)
        try await store.save([firstSegment, laterSegment])

        let root = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: firstMeeting.id,
            segmentID: firstSegment.id,
            sourceTranscriptRevision: firstMeeting.transcriptRevision,
            observedLabel: "Atlas program",
            language: "en",
            origin: .manual,
            confirmedAt: Self.baseDate.addingTimeInterval(10)))
        let observed = try await store.linkTopic(
            TopicLinkProposal(
                meetingID: laterMeeting.id,
                segmentID: laterSegment.id,
                sourceTranscriptRevision: laterMeeting.transcriptRevision,
                observedLabel: "Programa Atlas",
                language: "es",
                origin: .manual,
                confirmedAt: laterMeeting.startedAt.addingTimeInterval(10)),
            to: root.topic.id)
        return FirstDiscussionFixture(
            store: store,
            firstMeeting: firstMeeting,
            firstSegment: firstSegment,
            rootTopicID: root.topic.id,
            observedTopicID: observed.observedTopic.id,
            firstEvidenceID: root.evidence.id)
    }
}

private struct FirstDiscussionFixture {
    let store: MeetingStore
    let firstMeeting: Meeting
    let firstSegment: TranscriptSegment
    let rootTopicID: TopicID
    let observedTopicID: TopicID
    let firstEvidenceID: TopicMeetingEvidenceID
}

private actor FirstDiscussionRepositoryStub: TopicFirstDiscussionReading {
    let result: MeetingMemoryGraphQueryResult
    private(set) var receivedQuery: TopicFirstDiscussionQuery?

    init(result: MeetingMemoryGraphQueryResult) {
        self.result = result
    }

    func topicFirstDiscussion(
        _ query: TopicFirstDiscussionQuery
    ) -> MeetingMemoryGraphQueryResult {
        receivedQuery = query
        return result
    }
}

@discardableResult
private func projectFirstDiscussionGraph(
    in store: MeetingStore
) async throws -> MeetingMemoryGraphProjectionResult {
    let owner = "first-discussion-query-test-\(UUID().uuidString)"
    let sourceGeneration = try await store.database.read { database in
        try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM derivedMaintenanceSource
                WHERE kind = 'meeting-memory-graph'
                """) ?? 0
    }
    let timestamp = Date(timeIntervalSince1970: 1_787_110_000)
        .addingTimeInterval(TimeInterval(sourceGeneration))
    _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
    let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp)
    guard let job else {
        throw StorageError.invalidDerivedMaintenanceJob(
            "first-discussion fixture could not claim projection")
    }
    let result = try await ProjectMeetingMemoryGraph(
        store: store,
        now: { timestamp }).all(job: job, owner: owner)
    _ = try await store.completeMeetingMemoryGraphMaintenance(
        job.id,
        owner: owner,
        at: timestamp)
    return result
}
