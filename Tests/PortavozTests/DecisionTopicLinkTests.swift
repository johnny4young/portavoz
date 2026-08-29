import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import ApplicationKit

@testable import StorageKit

/// The decision↔topic authority (GRAPH-5a). The graph may only select topology
/// that authoritative storage asserts, so "this decision is about this topic"
/// gets explicit confirmation over evidence the decision already owns — and
/// meeting co-occurrence alone can never produce the edge.
final class DecisionTopicLinkTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Migration

    func testV32MigratesAdditivelyToDecisionTopicAuthority() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v31")

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 46)
            XCTAssertEqual(
                try Set(database.columns(in: "decisionTopicLink").map(\.name)),
                ["id", "decisionID", "topicID", "status", "createdAt",
                 "updatedAt", "deletedAt"])
            XCTAssertEqual(
                try Set(database.columns(in: "decisionTopicLinkSource").map(\.name)),
                ["id", "linkID", "summaryDecisionID", "summaryID", "meetingID",
                 "observedStatement", "observedTopicLabel",
                 "sourceTranscriptRevision", "observedAt", "linkedAt"])
            XCTAssertEqual(
                try Set(database.columns(in: "decisionTopicLinkEvent").map(\.name)),
                ["id", "linkID", "kind", "sourceID", "occurredAt"])
            XCTAssertEqual(
                try Set(
                    database.columns(in: "meetingMemoryGraphDecisionTopic")
                        .map(\.name)),
                ["decisionID", "topicID"])
        }
    }

    // MARK: - Confirmation

    func testConfirmationLinksOverTheDecisionsOwnEvidence() async throws {
        let fixture = try await seededDecisionAndTopic()

        let continuity = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))

        XCTAssertEqual(continuity.link.status, .confirmed)
        XCTAssertEqual(continuity.link.decisionID, fixture.decisionID)
        XCTAssertEqual(continuity.link.topicID, fixture.topicID)
        XCTAssertEqual(continuity.source.observationID, fixture.observationID)
        XCTAssertEqual(
            continuity.source.observedStatement,
            fixture.statement,
            "the source quotes the exact statement the user confirmed over")
        XCTAssertEqual(continuity.source.meetingID, fixture.meetingID)
        XCTAssertEqual(continuity.events.map(\.kind), [.confirm])

        let byDecision = try await fixture.store.decisionTopicLinks(
            for: fixture.decisionID)
        let byTopic = try await fixture.store.decisionTopicLinks(
            for: fixture.topicID)
        XCTAssertEqual(byDecision.map(\.link.id), [continuity.link.id])
        XCTAssertEqual(byTopic.map(\.link.id), [continuity.link.id])
    }

    /// The structural rule of the slice: evidence that the decision does not
    /// already own cannot found a link, however plausible the pairing looks.
    func testForeignEvidenceCannotFoundALink() async throws {
        let fixture = try await seededDecisionAndTopic()
        // A real observation, confirmed into a DIFFERENT decision.
        let other = try await DecisionContinuityTests.seedObservation(
            fixture.store,
            statement: "Adopt the other plan.",
            evidenceTexts: ["We adopt the other plan."],
            startedAt: baseDate.addingTimeInterval(600))
        _ = try await fixture.store.confirmDecision(DecisionConfirmation(
            observationID: other.observationID,
            confirmedAt: baseDate.addingTimeInterval(660)))

        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: fixture.decisionID,
                    topicID: fixture.topicID,
                    observationID: other.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(700)))
        }
    }

    func testMergedAndMissingTopicsAreRefused() async throws {
        let fixture = try await seededDecisionAndTopic()
        // Merge a second topic into the fixture root, then try to link the
        // merged (non-root) identity.
        let merged = try await fixture.store.linkTopic(
            TopicLinkProposal(
                meetingID: fixture.meetingID,
                segmentID: fixture.segmentID,
                sourceTranscriptRevision: 0,
                observedLabel: "Atlas rollout",
                language: "en",
                origin: .manual),
            to: fixture.topicID)

        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: fixture.decisionID,
                    topicID: merged.observedTopic.id,
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(700)))
        }
        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: fixture.decisionID,
                    topicID: TopicID(),
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(700)))
        }
    }

    func testOneActiveLinkPerPairAndIdempotentReplay() async throws {
        let fixture = try await seededDecisionAndTopic()
        let confirmation = DecisionTopicLinkConfirmation(
            decisionID: fixture.decisionID,
            topicID: fixture.topicID,
            observationID: fixture.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        let first = try await fixture.store.confirmDecisionTopicLink(confirmation)

        // Exact replay returns the existing link.
        let replay = try await fixture.store.confirmDecisionTopicLink(confirmation)
        XCTAssertEqual(replay.link.id, first.link.id)

        // The same identity with different content is refused.
        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    linkID: confirmation.linkID,
                    sourceID: confirmation.sourceID,
                    eventID: confirmation.eventID,
                    decisionID: fixture.decisionID,
                    topicID: TopicID(),
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(90)))
        }

        // A second active link for the same pair is refused outright.
        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: fixture.decisionID,
                    topicID: fixture.topicID,
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(120)))
        }
    }

    func testReusedChildIdentitiesLeaveNoPartialAuthority() async throws {
        let fixture = try await seededDecisionAndTopic()
        let confirmation = DecisionTopicLinkConfirmation(
            decisionID: fixture.decisionID,
            topicID: fixture.topicID,
            observationID: fixture.observationID,
            confirmedAt: baseDate.addingTimeInterval(60))
        let confirmed = try await fixture.store.confirmDecisionTopicLink(confirmation)
        _ = try await fixture.store.retractDecisionTopicLink(
            DecisionTopicLinkRetraction(
                linkID: confirmed.link.id,
                retractedAt: baseDate.addingTimeInterval(120)))
        let baseline = try await decisionTopicAuthorityRowCounts(in: fixture.store)

        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    sourceID: confirmation.sourceID,
                    decisionID: fixture.decisionID,
                    topicID: fixture.topicID,
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(180)))
        }
        await assertRefused {
            _ = try await fixture.store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    eventID: confirmation.eventID,
                    decisionID: fixture.decisionID,
                    topicID: fixture.topicID,
                    observationID: fixture.observationID,
                    confirmedAt: self.baseDate.addingTimeInterval(240)))
        }

        let finalCounts = try await decisionTopicAuthorityRowCounts(in: fixture.store)
        XCTAssertEqual(
            finalCounts,
            baseline,
            "child-identity collisions must roll back every candidate row")
    }

    // MARK: - Retraction

    func testRetractionIsTerminalAndThePairCanBeRelinked() async throws {
        let fixture = try await seededDecisionAndTopic()
        let confirmed = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))

        let retraction = DecisionTopicLinkRetraction(
            linkID: confirmed.link.id,
            retractedAt: baseDate.addingTimeInterval(120))
        let retracted = try await fixture.store.retractDecisionTopicLink(retraction)
        XCTAssertEqual(retracted.link.status, .retracted)
        XCTAssertEqual(retracted.events.map(\.kind), [.confirm, .retract])

        // Replay of the same retraction returns the settled link.
        let replay = try await fixture.store.retractDecisionTopicLink(retraction)
        XCTAssertEqual(replay.link.status, .retracted)

        // A fresh retraction of a retracted link is refused.
        await assertRefused {
            _ = try await fixture.store.retractDecisionTopicLink(
                DecisionTopicLinkRetraction(
                    linkID: confirmed.link.id,
                    retractedAt: self.baseDate.addingTimeInterval(180)))
        }

        // The pair can be linked again as a NEW link with fresh history —
        // a mis-click retraction must not poison the pair forever.
        let relinked = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(240)))
        XCTAssertNotEqual(relinked.link.id, confirmed.link.id)
        XCTAssertEqual(relinked.link.status, .confirmed)

        let active = try await fixture.store.decisionTopicLinks(
            for: fixture.decisionID)
        XCTAssertEqual(active.map(\.link.id), [relinked.link.id])
    }

    /// A backward clock step must not make retraction impossible: the
    /// transition trigger demands a strictly later updatedAt, so the store
    /// clamps forward exactly as the decision timestamp policy does.
    func testABackwardClockStepStillRetracts() async throws {
        let fixture = try await seededDecisionAndTopic()
        let confirmed = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))

        let retracted = try await fixture.store.retractDecisionTopicLink(
            DecisionTopicLinkRetraction(
                linkID: confirmed.link.id,
                retractedAt: baseDate.addingTimeInterval(-3_600)))

        XCTAssertEqual(retracted.link.status, .retracted)
        XCTAssertGreaterThan(
            retracted.link.updatedAt,
            confirmed.link.updatedAt)
    }

    // MARK: - The schema is the last line of defence

    func testDirectSQLCannotForgeAboutness() async throws {
        let fixture = try await seededDecisionAndTopic()
        let confirmed = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))

        // History rows refuse mutation outright.
        await assertRefused {
            try await fixture.store.database.write { database in
                try database.execute(
                    sql: """
                        UPDATE decisionTopicLinkSource
                        SET observedStatement = 'forged'
                        WHERE linkID = ?
                        """,
                    arguments: [confirmed.link.id.rawValue.uuidString])
            }
        }
        // The projection cannot transition without its matching event.
        let forgedDate = baseDate.addingTimeInterval(999)
        await assertRefused {
            try await fixture.store.database.write { database in
                try database.execute(
                    sql: """
                        UPDATE decisionTopicLink
                        SET status = 'retracted', updatedAt = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        forgedDate,
                        confirmed.link.id.rawValue.uuidString,
                    ])
            }
        }
        // The link's identity is immutable.
        await assertRefused {
            try await fixture.store.database.write { database in
                try database.execute(
                    sql: "UPDATE decisionTopicLink SET topicID = ? WHERE id = ?",
                    arguments: [
                        TopicID().rawValue.uuidString,
                        confirmed.link.id.rawValue.uuidString,
                    ])
            }
        }
    }

    /// The aboutness rule holds below Swift too: a confirm event whose source
    /// names an observation the decision does not own is refused by the v32
    /// trigger, so no code path — present or future — can widen the authority.
    func testTheTriggerRefusesForeignEvidenceEvenFromDirectSQL() async throws {
        let fixture = try await seededDecisionAndTopic()
        let foreignObservation = SummaryDecisionID()
        let linkID = DecisionTopicLinkID()
        let sourceID = DecisionTopicLinkSourceID()
        let stamp = baseDate.addingTimeInterval(60)
        let statement = fixture.statement

        await assertRefused {
            try await fixture.store.database.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO decisionTopicLink (
                            id, decisionID, topicID, status,
                            createdAt, updatedAt, deletedAt
                        ) VALUES (?, ?, ?, 'confirmed', ?, ?, NULL)
                        """,
                    arguments: [
                        linkID.rawValue.uuidString,
                        fixture.decisionID.rawValue.uuidString,
                        fixture.topicID.rawValue.uuidString,
                        stamp, stamp,
                    ])
                try database.execute(
                    sql: """
                        INSERT INTO decisionTopicLinkSource (
                            id, linkID, summaryDecisionID, summaryID, meetingID,
                            observedStatement, observedTopicLabel,
                            sourceTranscriptRevision, observedAt, linkedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, 'atlas-001', 0, ?, ?)
                        """,
                    arguments: [
                        sourceID.rawValue.uuidString,
                        linkID.rawValue.uuidString,
                        foreignObservation.rawValue.uuidString,
                        SummaryID().rawValue.uuidString,
                        fixture.meetingID.rawValue.uuidString,
                        statement,
                        stamp, stamp,
                    ])
                try database.execute(
                    sql: """
                        INSERT INTO decisionTopicLinkEvent (
                            id, linkID, kind, sourceID, occurredAt
                        ) VALUES (?, ?, 'confirm', ?, ?)
                        """,
                    arguments: [
                        DecisionTopicLinkEventID().rawValue.uuidString,
                        linkID.rawValue.uuidString,
                        sourceID.rawValue.uuidString,
                        stamp,
                    ])
            }
        }
    }

    // MARK: - Graph derivation

    /// The acceptance line of the whole slice: a decision confirmed in a
    /// meeting that also carries topic evidence produces NO decision-topic
    /// edge until the aboutness is explicitly confirmed — and the edge
    /// disappears again when the link is retracted.
    func testCoOccurrenceAloneNeverProducesTheEdge() async throws {
        let fixture = try await seededDecisionAndTopic()
        _ = try await projectAll(in: fixture.store)
        var snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertEqual(
            snapshot.meetingDecisions.map(\.decisionID),
            [fixture.decisionID],
            "the decision reached the graph through its own meeting")
        XCTAssertEqual(
            snapshot.meetingTopics.map(\.topicID),
            [fixture.topicID],
            "the topic reached the graph through its own evidence")
        XCTAssertTrue(
            snapshot.decisionTopics.isEmpty,
            "same meeting, both present — still no aboutness")

        // An *incremental* decision-only rebuild must hold the same line. The
        // full pass above processes every scope and the topic scope runs last,
        // so a co-occurrence bug in the decision scope alone would be silently
        // corrected by it — this step pins the scope that would go unchecked.
        let later = try await DecisionContinuityTests.seedObservation(
            fixture.store,
            statement: fixture.statement,
            evidenceTexts: ["Confirmed again: ship atlas-001 behind the flag."],
            startedAt: baseDate.addingTimeInterval(400))
        _ = try await fixture.store.linkDecisionSource(DecisionSourceConfirmation(
            decisionID: fixture.decisionID,
            observationID: later.observationID,
            confirmedAt: baseDate.addingTimeInterval(460)))
        _ = try await projectAll(in: fixture.store)
        snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertTrue(
            snapshot.decisionTopics.isEmpty,
            "a decision-scope rebuild alone must not manufacture aboutness")

        let confirmed = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))
        _ = try await projectAll(in: fixture.store)
        snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertEqual(
            snapshot.decisionTopics,
            [.init(decisionID: fixture.decisionID, topicID: fixture.topicID)])

        _ = try await fixture.store.retractDecisionTopicLink(
            DecisionTopicLinkRetraction(
                linkID: confirmed.link.id,
                retractedAt: baseDate.addingTimeInterval(120)))
        _ = try await projectAll(in: fixture.store)
        snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertTrue(
            snapshot.decisionTopics.isEmpty,
            "a retracted link withdraws its edge on rebuild")
    }

    func testTheEdgeFollowsTheTopicFamilyRoot() async throws {
        let fixture = try await seededDecisionAndTopic()
        _ = try await fixture.store.confirmDecisionTopicLink(
            DecisionTopicLinkConfirmation(
                decisionID: fixture.decisionID,
                topicID: fixture.topicID,
                observationID: fixture.observationID,
                confirmedAt: baseDate.addingTimeInterval(60)))
        // Merge the linked topic into a NEW root: traversal must follow the
        // family's current root without rewriting the authority row.
        let successor = try await fixture.store.createTopicAndLink(
            TopicLinkProposal(
                meetingID: fixture.meetingID,
                segmentID: fixture.segmentID,
                sourceTranscriptRevision: 0,
                observedLabel: "Atlas program",
                language: "en",
                origin: .manual))
        _ = try await fixture.store.mergeTopics(
            sourceTopicID: fixture.topicID,
            into: successor.topic.id,
            at: baseDate.addingTimeInterval(90))

        _ = try await projectAll(in: fixture.store)

        let snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertEqual(
            snapshot.decisionTopics,
            [.init(decisionID: fixture.decisionID, topicID: successor.topic.id)],
            "the edge targets the current family root")
        let links = try await fixture.store.decisionTopicLinks(
            for: fixture.topicID)
        XCTAssertEqual(
            links.map(\.link.topicID),
            [fixture.topicID],
            "the authority row still names the identity the user confirmed")
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: MeetingStore
        let decisionID: DecisionID
        let topicID: TopicID
        let observationID: SummaryDecisionID
        let meetingID: MeetingID
        let segmentID: UUID
        let statement: String
    }

    /// One meeting carrying BOTH a confirmed decision and confirmed topic
    /// evidence — deliberately, so every test runs against the exact
    /// co-occurrence shape the authority exists to keep out of the graph.
    private func seededDecisionAndTopic() async throws -> Fixture {
        let store = try MeetingStore.inMemory()
        let seeded = try await DecisionContinuityTests.seedObservation(
            store,
            statement: "Ship atlas-001 behind the flag.",
            evidenceTexts: ["We ship atlas-001 behind the flag."],
            startedAt: baseDate)
        let confirmation = DecisionConfirmation(
            observationID: seeded.observationID,
            confirmedAt: baseDate.addingTimeInterval(30))
        _ = try await store.confirmDecision(confirmation)
        let topic = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: seeded.meeting.id,
            segmentID: seeded.segments[0].id,
            sourceTranscriptRevision: seeded.meeting.transcriptRevision,
            observedLabel: "atlas-001",
            language: "en",
            origin: .manual))
        return Fixture(
            store: store,
            decisionID: confirmation.decisionID,
            topicID: topic.topic.id,
            observationID: seeded.observationID,
            meetingID: seeded.meeting.id,
            segmentID: seeded.segments[0].id,
            statement: seeded.statement)
    }

    private var projectionRuns = 0

    private func decisionTopicAuthorityRowCounts(
        in store: MeetingStore
    ) async throws -> [Int] {
        try await store.database.read { database in
            [
                try DecisionTopicLinkRecord.fetchCount(database),
                try DecisionTopicLinkSourceRecord.fetchCount(database),
                try DecisionTopicLinkEventRecord.fetchCount(database)
            ]
        }
    }

    @discardableResult
    private func projectAll(
        in store: MeetingStore
    ) async throws -> MeetingMemoryGraphProjectionResult {
        projectionRuns += 1
        let owner = "decision-topic-test-\(projectionRuns)"
        let timestamp = baseDate.addingTimeInterval(
            TimeInterval(10_000 + projectionRuns * 100))
        _ = try await store.admitMeetingMemoryGraphMaintenance(
            targetFingerprint: MeetingMemoryGraphProjectionProfile.fingerprint,
            at: timestamp)
        let claimed = try await store.claimMeetingMemoryGraphMaintenance(
            targetFingerprint: MeetingMemoryGraphProjectionProfile.fingerprint,
            owner: owner,
            leaseDuration: 120,
            at: timestamp)
        let job = try XCTUnwrap(claimed)
        let result = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }).all(
            job: job,
            owner: owner,
            batchSize: 64)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
        return result
    }

    private func assertRefused(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("the operation must be refused", file: file, line: line)
        } catch {}
    }
}
