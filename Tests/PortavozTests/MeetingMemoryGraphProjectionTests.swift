import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingMemoryGraphProjectionTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_786_500_000)

    func testV26MigratesAdditivelyAndSeedsEveryExistingAuthorityScope() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v26")
        let baseDate = Self.baseDate
        let meeting = Meeting(title: "Legacy graph authority", startedAt: baseDate)
        let personID = PersonID()
        let topicID = TopicID()
        let decisionID = DecisionID()
        let commitmentID = CommitmentID()
        try database.write { database in
            try MeetingRecord(
                meeting,
                createdAt: baseDate,
                updatedAt: baseDate)
                .insert(database)
            try database.execute(
                sql: """
                    INSERT INTO person (
                        id, preferredName, createdAt, updatedAt, deletedAt
                    ) VALUES (?, 'Ana', ?, ?, NULL)
                    """,
                arguments: [personID.rawValue.uuidString, baseDate, baseDate])
            try database.execute(
                sql: """
                    INSERT INTO topic (
                        id, preferredLabel, mergedIntoTopicID,
                        createdAt, updatedAt, deletedAt
                    ) VALUES (?, 'Release plan', NULL, ?, ?, NULL)
                    """,
                arguments: [topicID.rawValue.uuidString, baseDate, baseDate])
            try database.execute(
                sql: """
                    INSERT INTO decisionContinuity (
                        id, statement, status, createdAt, updatedAt, deletedAt
                    ) VALUES (?, 'Ship the release.', 'confirmed', ?, ?, NULL)
                    """,
                arguments: [decisionID.rawValue.uuidString, baseDate, baseDate])
            try database.execute(
                sql: """
                    INSERT INTO commitment (
                        id, canonicalPersonID, title, status, dueAt,
                        createdAt, updatedAt, deletedAt, assigneeKind
                    ) VALUES (?, ?, 'Prepare release notes', 'confirmed', NULL,
                              ?, ?, NULL, 'person')
                    """,
                arguments: [
                    commitmentID.rawValue.uuidString,
                    personID.rawValue.uuidString,
                    baseDate,
                    baseDate,
                ])
        }

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 27)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v27")
            XCTAssertEqual(
                try Set(database.columns(in: "meetingMemoryGraphProjectionState").map(\.name)),
                ["id", "profileFingerprint", "sourceGeneration", "updatedAt"])
            XCTAssertEqual(
                try Set(database.columns(in: "meetingMemoryGraphInvalidation").map(\.name)),
                ["scopeKind", "scopeID", "sourceGeneration", "createdAt"])
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT sourceGeneration FROM derivedMaintenanceSource
                        WHERE kind = 'meeting-memory-graph'
                        """),
                1)
            XCTAssertEqual(
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT scopeKind, scopeID, sourceGeneration
                        FROM meetingMemoryGraphInvalidation
                        ORDER BY scopeKind, scopeID
                        """)
                    .map { row in
                        "\(row["scopeKind"] as String):\(row["scopeID"] as String):\(row["sourceGeneration"] as Int)"
                    },
                [
                    "commitment:\(commitmentID.rawValue.uuidString):1",
                    "decision:\(decisionID.rawValue.uuidString):1",
                    "meeting:\(meeting.id.rawValue.uuidString):1",
                    "person:\(personID.rawValue.uuidString):1",
                    "topic:\(topicID.rawValue.uuidString):1",
                ])
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testProjectionPublishesTypedEdgesAndCanonicalizesMergedTopics() async throws {
        let fixture = try await seededGraphFixture()
        let result = try await projectAll(in: fixture.store, batchSize: 2)
        let snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        let pending = try await fixture.store.pendingMeetingMemoryGraphInvalidationCount()
        let requiresMaintenance = try await fixture.store
            .meetingMemoryGraphRequiresMaintenance()

        XCTAssertTrue(result.resetProjection)
        XCTAssertGreaterThanOrEqual(result.publishedEdges, 5)
        XCTAssertFalse(result.pausedByPolicy)
        XCTAssertEqual(
            snapshot.meetingPeople,
            [.init(meetingID: fixture.meeting.id, personID: fixture.personID)])
        XCTAssertEqual(
            snapshot.meetingTopics,
            [.init(meetingID: fixture.meeting.id, topicID: fixture.rootTopicID)])
        XCTAssertFalse(snapshot.meetingTopics.contains {
            $0.topicID == fixture.observedTopicID
        })
        XCTAssertEqual(
            snapshot.meetingDecisions,
            [.init(meetingID: fixture.meeting.id, decisionID: fixture.decisionID)])
        XCTAssertEqual(
            snapshot.meetingCommitments,
            [.init(meetingID: fixture.meeting.id, commitmentID: fixture.commitmentID)])
        XCTAssertEqual(
            snapshot.commitmentPeople,
            [.init(commitmentID: fixture.commitmentID, personID: fixture.personID)])
        XCTAssertEqual(pending, 0)
        XCTAssertFalse(requiresMaintenance)
    }

    func testPartialBatchDoesNotAdvanceHighWaterAndBoundedChangesRemoveEdges() async throws {
        let fixture = try await seededGraphFixture()
        _ = try await projectAll(in: fixture.store)
        let completedGeneration = try await projectionGeneration(in: fixture.store)

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE speaker SET personID = NULL WHERE id = ?",
                arguments: [fixture.speakerID.rawValue.uuidString])
        }
        _ = try await fixture.store.applyCommitmentTransition(
            .reassign(.unassigned),
            to: fixture.commitmentID,
            at: Self.baseDate.addingTimeInterval(60))
        let pendingGeneration = try await sourceGeneration(in: fixture.store)
        let owner = "graph-partial-owner"
        let job = try await claimGraphJob(in: fixture.store, owner: owner)

        let first = try await fixture.store.projectMeetingMemoryGraphBatch(
            jobID: job.id,
            owner: owner,
            through: pendingGeneration,
            limit: 1)
        let generationAfterFirst = try await projectionGeneration(in: fixture.store)
        let pendingAfterFirst = try await fixture.store
            .pendingMeetingMemoryGraphInvalidationCount()

        XCTAssertEqual(first.rebuiltScopes, 1)
        XCTAssertEqual(generationAfterFirst, completedGeneration)
        XCTAssertGreaterThan(pendingAfterFirst, 0)
        do {
            _ = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
            XCTFail("A partially rebuilt graph must fail closed")
        } catch {
            XCTAssertTrue(error is StorageError)
        }

        let second = try await fixture.store.projectMeetingMemoryGraphBatch(
            jobID: job.id,
            owner: owner,
            through: pendingGeneration,
            limit: 16)
        let snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        let completedAfterSecond = try await projectionGeneration(in: fixture.store)
        let pendingAfterSecond = try await fixture.store
            .pendingMeetingMemoryGraphInvalidationCount()

        XCTAssertGreaterThanOrEqual(second.rebuiltScopes, 1)
        XCTAssertEqual(completedAfterSecond, pendingGeneration)
        XCTAssertTrue(snapshot.meetingPeople.isEmpty)
        XCTAssertTrue(snapshot.commitmentPeople.isEmpty)
        XCTAssertEqual(snapshot.meetingCommitments.count, 1)
        XCTAssertEqual(pendingAfterSecond, 0)
    }

    func testCorrectionAndDeletionInvalidateOnlyTheMeetingSubgraph() async throws {
        let fixture = try await seededGraphFixture()
        _ = try await projectAll(in: fixture.store)

        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET transcriptRevision = 1 WHERE id = ?",
                arguments: [fixture.meeting.id.rawValue.uuidString])
        }
        let correctedScopes = try await pendingScopes(in: fixture.store)
        XCTAssertEqual(correctedScopes, ["meeting:\(fixture.meeting.id.rawValue.uuidString)"])
        _ = try await projectAll(in: fixture.store)
        let afterCorrection = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
        XCTAssertEqual(afterCorrection.meetingTopics.count, 1)
        XCTAssertEqual(afterCorrection.meetingDecisions.count, 1)

        let deletedAt = Self.baseDate.addingTimeInterval(120)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET deletedAt = ? WHERE id = ?",
                arguments: [deletedAt, fixture.meeting.id.rawValue.uuidString])
        }
        let deletedScopes = try await pendingScopes(in: fixture.store)
        XCTAssertEqual(deletedScopes, ["meeting:\(fixture.meeting.id.rawValue.uuidString)"])
        _ = try await projectAll(in: fixture.store)
        let afterDeletion = try await fixture.store.meetingMemoryGraphProjectionSnapshot()

        XCTAssertTrue(afterDeletion.meetingPeople.isEmpty)
        XCTAssertTrue(afterDeletion.meetingTopics.isEmpty)
        XCTAssertTrue(afterDeletion.meetingDecisions.isEmpty)
        XCTAssertTrue(afterDeletion.meetingCommitments.isEmpty)
        XCTAssertEqual(afterDeletion.commitmentPeople.count, 1)
    }

    func testNonTopologyLifecycleChangesDoNotScheduleProjectionWork() async throws {
        let fixture = try await seededGraphFixture()
        _ = try await projectAll(in: fixture.store)
        let completedGeneration = try await sourceGeneration(in: fixture.store)
        let triggerSQL = try await fixture.store.database.read { database in
            try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    database,
                    sql: """
                        SELECT name, sql FROM sqlite_master
                        WHERE type = 'trigger'
                          AND name IN (
                              'memoryGraphDecision_au',
                              'memoryGraphCommitment_au'
                          )
                        """)
                    .map { row in
                        (row["name"] as String, row["sql"] as String)
                    })
        }

        _ = try await fixture.store.applyCommitmentTransition(
            .reschedule(Self.baseDate.addingTimeInterval(3_600)),
            to: fixture.commitmentID,
            at: Self.baseDate.addingTimeInterval(180))
        _ = try await fixture.store.applyCommitmentTransition(
            .complete,
            to: fixture.commitmentID,
            at: Self.baseDate.addingTimeInterval(181))

        let currentGeneration = try await sourceGeneration(in: fixture.store)
        let scopes = try await pendingScopes(in: fixture.store)

        XCTAssertFalse(try XCTUnwrap(triggerSQL["memoryGraphDecision_au"])
            .contains("UPDATE OF status"))
        let commitmentTrigger = try XCTUnwrap(triggerSQL["memoryGraphCommitment_au"])
        XCTAssertFalse(commitmentTrigger.contains("UPDATE OF status"))
        XCTAssertFalse(commitmentTrigger.contains("dueAt"))
        XCTAssertEqual(currentGeneration, completedGeneration)
        XCTAssertTrue(scopes.isEmpty)
    }

    func testProfileChangeRebuildsEveryScopeWithoutTouchingAuthority() async throws {
        let fixture = try await seededGraphFixture()
        _ = try await projectAll(in: fixture.store)
        let alternateFingerprint = String(repeating: "a", count: 64)
        let owner = "graph-alternate-profile-owner"
        let job = try await claimGraphJob(
            in: fixture.store,
            owner: owner,
            targetFingerprint: alternateFingerprint)

        let rebuilt = try await ProjectMeetingMemoryGraph(store: fixture.store).all(
            job: job,
            owner: owner,
            batchSize: 1)
        let storedFingerprint = try await projectionFingerprint(in: fixture.store)
        let counts = try await graphEdgeCounts(in: fixture.store)
        let requiresDefaultProfile = try await fixture.store
            .meetingMemoryGraphRequiresMaintenance()

        XCTAssertTrue(rebuilt.resetProjection)
        XCTAssertGreaterThanOrEqual(rebuilt.rebuiltScopes, 5)
        XCTAssertEqual(storedFingerprint, alternateFingerprint)
        XCTAssertEqual(counts, [1, 1, 1, 1, 1])
        XCTAssertTrue(requiresDefaultProfile)
        do {
            _ = try await fixture.store.meetingMemoryGraphProjectionSnapshot()
            XCTFail("The default snapshot must reject an alternate profile")
        } catch {
            XCTAssertTrue(error is StorageError)
        }
    }

    func testGovernorPauseCommitsOneBatchAndResumeDrainsTheCursor() async throws {
        let fixture = try await seededGraphFixture()
        let owner = "graph-governor-owner"
        let job = try await claimGraphJob(in: fixture.store, owner: owner)
        let pausedProjector = ProjectMeetingMemoryGraph(
            store: fixture.store,
            maintenanceGate: DurableMaintenanceGate { _, phase in
                phase == .admission ? .proceed : .pause
            })

        let paused = try await pausedProjector.all(
            job: job,
            owner: owner,
            batchSize: 1)
        let pendingAfterPause = try await fixture.store
            .pendingMeetingMemoryGraphInvalidationCount()

        XCTAssertEqual(paused.rebuiltScopes, 1)
        XCTAssertTrue(paused.pausedByPolicy)
        XCTAssertGreaterThan(pendingAfterPause, 0)

        let resumed = try await ProjectMeetingMemoryGraph(store: fixture.store).all(
            job: job,
            owner: owner,
            batchSize: 1)
        let pendingAfterResume = try await fixture.store
            .pendingMeetingMemoryGraphInvalidationCount()

        XCTAssertFalse(resumed.pausedByPolicy)
        XCTAssertGreaterThan(resumed.rebuiltScopes, 0)
        XCTAssertEqual(pendingAfterResume, 0)
    }

    func testExpiredLeaseResumesCommittedCursorWithoutDuplicateEdges() async throws {
        let fixture = try await seededGraphFixture()
        let startedAt = Self.baseDate.addingTimeInterval(300)
        let admitted = try await fixture.store.admitMeetingMemoryGraphMaintenance(
            at: startedAt)
        let claimedBeforeRelaunch = try await fixture.store.claimMeetingMemoryGraphMaintenance(
            owner: "graph-owner-before-relaunch",
            leaseDuration: 1,
            at: startedAt)
        let first = try XCTUnwrap(claimedBeforeRelaunch)
        let partial = try await fixture.store.projectMeetingMemoryGraphBatch(
            jobID: first.id,
            owner: "graph-owner-before-relaunch",
            through: first.sourceGeneration,
            limit: 1,
            at: startedAt)

        let relaunchedAt = startedAt.addingTimeInterval(2)
        let recovered = try await fixture.store.recoverExpiredMeetingMemoryGraphMaintenance(
            at: relaunchedAt)
        XCTAssertEqual(recovered, 1)
        do {
            _ = try await fixture.store.projectMeetingMemoryGraphBatch(
                jobID: first.id,
                owner: "graph-owner-before-relaunch",
                through: first.sourceGeneration,
                at: relaunchedAt)
            XCTFail("An expired owner must not publish")
        } catch {
            XCTAssertTrue(error is StorageError)
        }
        let claimedAfterRelaunch = try await fixture.store.claimMeetingMemoryGraphMaintenance(
            owner: "graph-owner-after-relaunch",
            leaseDuration: 60,
            at: relaunchedAt)
        let second = try XCTUnwrap(claimedAfterRelaunch)
        _ = try await ProjectMeetingMemoryGraph(
            store: fixture.store,
            now: { relaunchedAt }).all(
            job: second,
            owner: "graph-owner-after-relaunch",
            batchSize: 1)
        let completed = try await fixture.store.completeMeetingMemoryGraphMaintenance(
            second.id,
            owner: "graph-owner-after-relaunch",
            at: relaunchedAt.addingTimeInterval(1))
        let jobs = try await fixture.store.derivedMaintenanceJobs(kind: .meetingMemoryGraph)
        let snapshot = try await fixture.store.meetingMemoryGraphProjectionSnapshot()

        XCTAssertEqual(first.id, admitted.id)
        XCTAssertEqual(second.id, admitted.id)
        XCTAssertEqual(partial.rebuiltScopes, 1)
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.attempt, 2)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(snapshot.meetingPeople.count, 1)
        XCTAssertEqual(snapshot.meetingTopics.count, 1)
        XCTAssertEqual(snapshot.meetingDecisions.count, 1)
        XCTAssertEqual(snapshot.meetingCommitments.count, 1)
        XCTAssertEqual(snapshot.commitmentPeople.count, 1)
    }

    func testCaptureDeniesDurableAdmission() async throws {
        let fixture = try await seededGraphFixture()
        let workflow = ProcessMeetingMemoryGraphMaintenance(
            store: fixture.store,
            projector: ProjectMeetingMemoryGraph(store: fixture.store),
            mayStart: { false })

        let result = try await workflow.execute(owner: "graph-capture-owner")
        let jobs = try await fixture.store.derivedMaintenanceJobs(kind: .meetingMemoryGraph)
        let pending = try await fixture.store.pendingMeetingMemoryGraphInvalidationCount()

        XCTAssertEqual(result, .paused)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertGreaterThan(pending, 0)
    }

    func testSemanticAndGraphMaintenanceOwnIndependentLeases() async throws {
        let fixture = try await seededGraphFixture()
        let fingerprint = MeetingMemoryGraphProjectionProfile.fingerprint
        _ = try await fixture.store.admitSemanticCorpusMaintenance(
            targetFingerprint: fingerprint)
        _ = try await fixture.store.admitMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint)
        let semantic = try await fixture.store.claimSemanticCorpusMaintenance(
            targetFingerprint: fingerprint,
            owner: "semantic-owner",
            leaseDuration: 60)
        let graph = try await fixture.store.claimMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint,
            owner: "graph-owner",
            leaseDuration: 60)

        let claimedSemantic = try XCTUnwrap(semantic)
        let claimedGraph = try XCTUnwrap(graph)
        XCTAssertNotEqual(claimedSemantic.id, claimedGraph.id)
        XCTAssertEqual(claimedSemantic.kind, .semanticCorpus)
        XCTAssertEqual(claimedGraph.kind, .meetingMemoryGraph)
        do {
            _ = try await fixture.store.completeSemanticCorpusMaintenance(
                claimedGraph.id,
                owner: "graph-owner")
            XCTFail("A derived owner must not settle another maintenance kind")
        } catch {
            XCTAssertTrue(error is StorageError)
        }
    }

    private struct GraphFixture {
        let store: MeetingStore
        let meeting: Meeting
        let speakerID: SpeakerID
        let personID: PersonID
        let rootTopicID: TopicID
        let observedTopicID: TopicID
        let decisionID: DecisionID
        let commitmentID: CommitmentID
    }

    private func seededGraphFixture() async throws -> GraphFixture {
        let store = try MeetingStore.inMemory()
        let baseDate = Self.baseDate
        let meeting = Meeting(title: "Graph projection", startedAt: baseDate)
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "The release plan is approved.",
                language: "en",
                startTime: 0,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "El plan de lanzamiento sigue aprobado.",
                language: "es",
                startTime: 5,
                endTime: 9,
                isFinal: true),
        ]
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        let person = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName)
        let rootTopic = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: meeting.id,
            segmentID: segments[0].id,
            sourceTranscriptRevision: meeting.transcriptRevision,
            observedLabel: "Release plan",
            language: "en",
            origin: .manual))
        let observedTopic = try await store.linkTopic(
            TopicLinkProposal(
                meetingID: meeting.id,
                segmentID: segments[1].id,
                sourceTranscriptRevision: meeting.transcriptRevision,
                observedLabel: "Plan de lanzamiento",
                language: "es",
                origin: .generatedSimilarity,
                similarityCandidate: TopicSimilarityCandidate(
                    topicID: rootTopic.topic.id,
                    similarity: 0.91,
                    profileFingerprint: "graph-projection-test-profile")),
            to: rootTopic.topic.id)
        let commitment = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare release notes",
                assignee: .person(person.person.id),
                origin: .manual(meetingID: meeting.id)),
            at: baseDate.addingTimeInterval(20))
        let decisionID = DecisionID()
        let decisionSourceID = DecisionSourceID()
        try await store.database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO decisionContinuity (
                        id, statement, status, createdAt, updatedAt, deletedAt
                    ) VALUES (?, 'Ship the release.', 'confirmed', ?, ?, NULL)
                    """,
                arguments: [decisionID.rawValue.uuidString, baseDate, baseDate])
            try database.execute(
                sql: """
                    INSERT INTO decisionContinuitySource (
                        id, decisionID, summaryDecisionID, summaryID, meetingID,
                        observedStatement, sourceTranscriptRevision, observedAt, linkedAt
                    ) VALUES (?, ?, ?, ?, ?, 'Ship the release.', 0, ?, ?)
                    """,
                arguments: [
                    decisionSourceID.rawValue.uuidString,
                    decisionID.rawValue.uuidString,
                    SummaryDecisionID().rawValue.uuidString,
                    SummaryID().rawValue.uuidString,
                    meeting.id.rawValue.uuidString,
                    baseDate,
                    baseDate,
                ])
            try database.execute(
                sql: """
                    INSERT INTO decisionContinuityEvidenceSegment (
                        sourceID, segmentID, ordinal
                    ) VALUES (?, ?, 0)
                    """,
                arguments: [
                    decisionSourceID.rawValue.uuidString,
                    segments[0].id.uuidString,
                ])
            try database.execute(
                sql: """
                    INSERT INTO decisionContinuityEvent (
                        id, decisionID, kind, sourceID, relatedDecisionID, occurredAt
                    ) VALUES (?, ?, 'confirm', ?, NULL, ?)
                    """,
                arguments: [
                    DecisionEventID().rawValue.uuidString,
                    decisionID.rawValue.uuidString,
                    decisionSourceID.rawValue.uuidString,
                    baseDate,
                ])
        }
        return GraphFixture(
            store: store,
            meeting: meeting,
            speakerID: speaker.id,
            personID: person.person.id,
            rootTopicID: rootTopic.topic.id,
            observedTopicID: observedTopic.observedTopic.id,
            decisionID: decisionID,
            commitmentID: commitment.commitment.id)
    }

    private func sourceGeneration(in store: MeetingStore) async throws -> Int {
        try await store.database.read { database in
            try XCTUnwrap(Int.fetchOne(
                database,
                sql: """
                    SELECT sourceGeneration FROM derivedMaintenanceSource
                    WHERE kind = 'meeting-memory-graph'
                    """))
        }
    }

    private func projectionGeneration(in store: MeetingStore) async throws -> Int {
        try await store.database.read { database in
            try XCTUnwrap(Int.fetchOne(
                database,
                sql: """
                    SELECT sourceGeneration FROM meetingMemoryGraphProjectionState
                    WHERE id = 'current'
                    """))
        }
    }

    private func projectionFingerprint(in store: MeetingStore) async throws -> String? {
        try await store.database.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT profileFingerprint FROM meetingMemoryGraphProjectionState
                    WHERE id = 'current'
                    """)
        }
    }

    private func pendingScopes(in store: MeetingStore) async throws -> [String] {
        try await store.database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT scopeKind, scopeID
                    FROM meetingMemoryGraphInvalidation
                    ORDER BY scopeKind, scopeID
                    """)
                .map { row in
                    "\(row["scopeKind"] as String):\(row["scopeID"] as String)"
                }
        }
    }

    private func claimGraphJob(
        in store: MeetingStore,
        owner: String,
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        at timestamp: Date = Date()
    ) async throws -> DerivedMaintenanceJob {
        _ = try await store.admitMeetingMemoryGraphMaintenance(
            targetFingerprint: targetFingerprint,
            at: timestamp)
        let claimed = try await store.claimMeetingMemoryGraphMaintenance(
            targetFingerprint: targetFingerprint,
            owner: owner,
            leaseDuration: 120,
            at: timestamp)
        return try XCTUnwrap(claimed)
    }

    @discardableResult
    private func projectAll(
        in store: MeetingStore,
        targetFingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint,
        batchSize: Int = 128
    ) async throws -> MeetingMemoryGraphProjectionResult {
        let owner = "graph-test-owner-\(UUID().uuidString)"
        let timestamp = Date()
        let job = try await claimGraphJob(
            in: store,
            owner: owner,
            targetFingerprint: targetFingerprint,
            at: timestamp)
        let result = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }).all(
            job: job,
            owner: owner,
            batchSize: batchSize)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
        return result
    }

    private func graphEdgeCounts(in store: MeetingStore) async throws -> [Int] {
        try await store.database.read { database in
            try [
                "meetingMemoryGraphMeetingPerson",
                "meetingMemoryGraphMeetingTopic",
                "meetingMemoryGraphMeetingDecision",
                "meetingMemoryGraphMeetingCommitment",
                "meetingMemoryGraphCommitmentPerson",
            ].map { table in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
    }
}
