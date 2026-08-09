import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

/// Boundary behavior of the decisionConflicts / changeSince adapters that the
/// canonical corpus does not exercise: the anchor cut, the topology
/// cross-check, filters, and stale evidence.
final class DecisionRelationshipQueryTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testChangeSinceExcludesRelationshipsAtOrBeforeTheAnchor() async throws {
        let fixture = try await seededRelationship()

        // Anchored at the successor's own meeting: the supersession event
        // (which occurred after both meetings) is a change since meeting one,
        // but not since a point after the event itself.
        let sinceFirst = try await fixture.store.changeSince(ChangeSinceQuery(
            topicID: fixture.topicID,
            sinceMeetingID: fixture.firstMeetingID))
        guard case .facts(let page) = sinceFirst else {
            return XCTFail("the replacement happened after the first meeting")
        }
        XCTAssertEqual(page.facts.map(\.kind), [.decisionSupersededDecision])

        // An anchor meeting that ends after the relationship event sees no
        // change: nothing changed since then.
        let lateAnchor = Meeting(
            title: "Later sync",
            startedAt: baseDate.addingTimeInterval(9_000),
            endedAt: baseDate.addingTimeInterval(9_060))
        try await fixture.store.save(lateAnchor)
        let sinceLate = try await fixture.store.changeSince(ChangeSinceQuery(
            topicID: fixture.topicID,
            sinceMeetingID: lateAnchor.id))
        XCTAssertEqual(sinceLate, .abstained(.noMatchingFacts))
    }

    func testChangeSinceAbstainsBeforeTopologyOnAMissingAnchor() async throws {
        let fixture = try await seededRelationship()

        let result = try await fixture.store.changeSince(ChangeSinceQuery(
            topicID: fixture.topicID,
            sinceMeetingID: MeetingID()))

        XCTAssertEqual(result, .abstained(.missingTemporalBaseline))
    }

    /// The graph may only confirm topology the authority asserts. A linked
    /// decision whose projection edge is missing is an inconsistency to
    /// surface, never to silently repair.
    func testAMissingProjectionEdgeAbstainsAsInconsistent() async throws {
        let fixture = try await seededRelationship()

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "DELETE FROM meetingMemoryGraphDecisionTopic")
        }

        let result = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(topicID: fixture.topicID))
        XCTAssertEqual(result, .abstained(.projectionInconsistent))
    }

    func testFiltersAndValidationFailClosed() async throws {
        let fixture = try await seededRelationship()

        // A supersession has no "active" reading.
        let active = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(
                topicID: fixture.topicID,
                filter: MeetingMemoryGraphFactFilter(status: .active)))
        XCTAssertEqual(active, .abstained(.noMatchingFacts))

        let invalid = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(topicID: fixture.topicID, itemLimit: 0))
        XCTAssertEqual(invalid, .abstained(.invalidQuery))

        let unknownTopic = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(topicID: TopicID()))
        XCTAssertEqual(unknownTopic, .abstained(.topicUnavailable))
    }

    /// Rewriting the transcript under a relationship's evidence makes the fact
    /// unservable, not silently served from stale text.
    func testStaleEvidenceAbstainsRatherThanServingOldText() async throws {
        let fixture = try await seededRelationship()

        let meetings = try await fixture.store.meetings()
        var meeting = try XCTUnwrap(
            meetings.first { $0.id == fixture.firstMeetingID })
        meeting.transcriptRevision += 1
        try await fixture.store.save(meeting)
        // The revision bump invalidates the projection; the adapter must first
        // see a ready graph again to reach the evidence check at all.
        try await Self.projectGraph(
            in: fixture.store,
            at: baseDate.addingTimeInterval(20_000))

        let result = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(topicID: fixture.topicID))
        XCTAssertEqual(result, .abstained(.staleEvidenceOnly))
    }

    /// The discriminator against proximity: a second decision pair lives in
    /// the *same meetings* and carries its own confirmed supersession, but is
    /// never linked to the topic. Aboutness by authority returns exactly the
    /// linked relationship; aboutness by co-occurrence would return both.
    func testUnlinkedCoOccurringDecisionsNeverEnterTheAnswer() async throws {
        let fixture = try await seededRelationship()

        let result = try await fixture.store.decisionConflicts(
            DecisionConflictsQuery(topicID: fixture.topicID))

        guard case .facts(let page) = result else {
            return XCTFail("the linked relationship must answer")
        }
        XCTAssertEqual(
            page.facts.map(\.subjectText),
            ["Ship atlas-100 every ten minutes."],
            "only the topic's own relationship answers; the co-occurring one stays out")
    }

    /// Once a page has enough current facts, later matches still determine
    /// `hasMore` but do not spend evidence reads or report omissions outside
    /// the requested page.
    func testDecisionHistoryCountsButDoesNotHydrateBeyondThePage() async throws {
        let fixture = try await seededRelationship()
        let later = try await DecisionContinuityTests.seedObservation(
            fixture.store,
            statement: "Keep an additional atlas-100 decision.",
            evidenceTexts: ["The additional atlas-100 decision stands."],
            startedAt: baseDate.addingTimeInterval(1_200),
            summaryCreatedAt: baseDate.addingTimeInterval(1_210))
        let confirmation = DecisionConfirmation(
            observationID: later.observationID,
            confirmedAt: baseDate.addingTimeInterval(1_300))
        _ = try await fixture.store.confirmDecision(confirmation)
        _ = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: confirmation.decisionID,
                topicID: fixture.topicID,
                observationID: confirmation.observationID,
                confirmedAt: baseDate.addingTimeInterval(1_400)))

        var staleMeeting = later.meeting
        staleMeeting.transcriptRevision += 1
        try await fixture.store.save(staleMeeting)
        try await Self.projectGraph(
            in: fixture.store,
            at: baseDate.addingTimeInterval(30_000))

        let result = try await fixture.store.decisionHistory(
            DecisionHistoryQuery(topicID: fixture.topicID, itemLimit: 1))
        guard case .facts(let page) = result else {
            return XCTFail("the first current decision must fill the page")
        }
        XCTAssertEqual(
            page.facts.map(\.subjectText),
            ["Ship atlas-100 every ten minutes."])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.omittedStaleCount, 0)
        XCTAssertEqual(page.omittedUnavailableCount, 0)
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: MeetingStore
        let topicID: TopicID
        let firstMeetingID: MeetingID
    }

    private static func projectGraph(
        in store: MeetingStore,
        at timestamp: Date
    ) async throws {
        let owner = "decision-relationship-query-\(UUID().uuidString)"
        _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
        let claimed = try await store.claimMeetingMemoryGraphMaintenance(
            owner: owner,
            leaseDuration: 120,
            at: timestamp)
        let job = try XCTUnwrap(claimed)
        _ = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }).all(job: job, owner: owner)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
    }

    /// One replaced decision (meeting one) and its confirmed successor
    /// (meeting two), both linked to one topic through the authority, with the
    /// projection published — all through public boundaries.
    private func seededRelationship() async throws -> Fixture {
        let store = try MeetingStore.inMemory()
        let old = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship atlas-100 hourly.",
            evidenceTexts: ["We ship atlas-100 hourly."],
            startedAt: baseDate,
            summaryCreatedAt: baseDate.addingTimeInterval(10))
        let new = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship atlas-100 every ten minutes.",
            evidenceTexts: ["We replaced hourly with ten-minute batches."],
            startedAt: baseDate.addingTimeInterval(600),
            summaryCreatedAt: baseDate.addingTimeInterval(610))

        let oldConfirmation = DecisionConfirmation(
            observationID: old.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        _ = try await store.confirmDecision(oldConfirmation)
        let newConfirmation = DecisionConfirmation(
            observationID: new.observationID,
            confirmedAt: baseDate.addingTimeInterval(700))
        _ = try await store.confirmDecision(newConfirmation)

        let topic = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: old.meeting.id,
            segmentID: old.segments[0].id,
            sourceTranscriptRevision: old.meeting.transcriptRevision,
            observedLabel: "atlas-100",
            language: "en",
            origin: .manual))
        for confirmation in [oldConfirmation, newConfirmation] {
            _ = try await store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: confirmation.decisionID,
                    topicID: topic.topic.id,
                    observationID: confirmation.observationID,
                    confirmedAt: baseDate.addingTimeInterval(800)))
        }
        _ = try await store.confirmDecisionRelationship(
            DecisionRelationshipConfirmation(
                targetDecisionID: oldConfirmation.decisionID,
                successorDecisionID: newConfirmation.decisionID,
                kind: .supersede,
                confirmedAt: baseDate.addingTimeInterval(900)))

        // The co-occurring, UNLINKED pair: confirmed decisions with their own
        // supersession, in the same meetings as the topic's evidence, that the
        // user never linked to the topic.
        let betaOldObservation = SummaryDecisionID()
        let betaOldSummaryAt = baseDate.addingTimeInterval(15)
        _ = try await store.database.write { database in
            try MeetingStore.insertSummarySnapshot(
                SummaryDraft(
                    meetingID: old.meeting.id,
                    recipeID: "decision-relationship-beta",
                    language: "en",
                    markdown: "# Summary\n\n## Decisions\n- Ship beta-200 monthly.",
                    actionItems: [],
                    decisionEvidence: [SummaryDecisionEvidence(
                        id: betaOldObservation,
                        sectionOrdinal: 0,
                        bulletOrdinal: 0,
                        sourceTranscriptRevision: old.meeting.transcriptRevision,
                        evidenceSegmentIDs: [old.segments[0].id])]),
                at: betaOldSummaryAt,
                in: database)
        }
        let betaNewObservation = SummaryDecisionID()
        let betaNewSummaryAt = baseDate.addingTimeInterval(615)
        _ = try await store.database.write { database in
            try MeetingStore.insertSummarySnapshot(
                SummaryDraft(
                    meetingID: new.meeting.id,
                    recipeID: "decision-relationship-beta",
                    language: "en",
                    markdown: "# Summary\n\n## Decisions\n- Ship beta-200 weekly.",
                    actionItems: [],
                    decisionEvidence: [SummaryDecisionEvidence(
                        id: betaNewObservation,
                        sectionOrdinal: 0,
                        bulletOrdinal: 0,
                        sourceTranscriptRevision: new.meeting.transcriptRevision,
                        evidenceSegmentIDs: [new.segments[0].id])]),
                at: betaNewSummaryAt,
                in: database)
        }
        let betaOld = DecisionConfirmation(
            observationID: betaOldObservation,
            confirmedAt: baseDate.addingTimeInterval(70))
        _ = try await store.confirmDecision(betaOld)
        let betaNew = DecisionConfirmation(
            observationID: betaNewObservation,
            confirmedAt: baseDate.addingTimeInterval(710))
        _ = try await store.confirmDecision(betaNew)
        _ = try await store.confirmDecisionRelationship(
            DecisionRelationshipConfirmation(
                targetDecisionID: betaOld.decisionID,
                successorDecisionID: betaNew.decisionID,
                kind: .supersede,
                confirmedAt: baseDate.addingTimeInterval(910)))

        try await Self.projectGraph(
            in: store,
            at: baseDate.addingTimeInterval(10_000))

        return Fixture(
            store: store,
            topicID: topic.topic.id,
            firstMeetingID: old.meeting.id)
    }

}
