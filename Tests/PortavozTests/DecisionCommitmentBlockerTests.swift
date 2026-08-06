import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DecisionCommitmentBlockerPolicyTests: XCTestCase {
    private let confirmedAt = Date(timeIntervalSince1970: 1_787_000_000)

    func testProjectionRequiresExactEvidenceAndAlternatingLifecycle() throws {
        let blockerID = DecisionCommitmentBlockerID()
        let evidence = DecisionCommitmentBlockerEvidence(
            meetingID: MeetingID(),
            sourceTranscriptRevision: 3,
            segmentIDs: [UUID(), UUID()])
        let clear = DecisionCommitmentBlockerEvent(
            blockerID: blockerID,
            kind: .clear,
            evidence: evidence,
            occurredAt: confirmedAt.addingTimeInterval(1))
        let reopen = DecisionCommitmentBlockerEvent(
            blockerID: blockerID,
            kind: .reopen,
            evidence: evidence,
            occurredAt: confirmedAt.addingTimeInterval(2))

        let blocker = try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blockerID,
            decisionID: DecisionID(),
            commitmentID: CommitmentID(),
            openingEvidence: evidence,
            confirmedAt: confirmedAt,
            events: [clear, reopen])

        XCTAssertEqual(blocker.status, .active)
        XCTAssertEqual(blocker.updatedAt, reopen.occurredAt)
        XCTAssertThrowsError(try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blockerID,
            decisionID: blocker.decisionID,
            commitmentID: blocker.commitmentID,
            openingEvidence: evidence,
            confirmedAt: confirmedAt,
            events: [reopen])) { error in
                XCTAssertEqual(
                    error as? DecisionCommitmentBlockerValidationError,
                    .invalidTransition)
            }
        XCTAssertThrowsError(try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blockerID,
            decisionID: blocker.decisionID,
            commitmentID: blocker.commitmentID,
            openingEvidence: DecisionCommitmentBlockerEvidence(
                meetingID: evidence.meetingID,
                sourceTranscriptRevision: evidence.sourceTranscriptRevision,
                segmentIDs: []),
            confirmedAt: confirmedAt,
            events: []))

        let duplicateID = DecisionCommitmentBlockerEventID()
        let duplicateEvents = [
            DecisionCommitmentBlockerEvent(
                id: duplicateID,
                blockerID: blockerID,
                kind: .clear,
                evidence: evidence,
                occurredAt: confirmedAt.addingTimeInterval(1)),
            DecisionCommitmentBlockerEvent(
                id: duplicateID,
                blockerID: blockerID,
                kind: .reopen,
                evidence: evidence,
                occurredAt: confirmedAt.addingTimeInterval(2))
        ]
        XCTAssertThrowsError(try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blockerID,
            decisionID: blocker.decisionID,
            commitmentID: blocker.commitmentID,
            openingEvidence: evidence,
            confirmedAt: confirmedAt,
            events: duplicateEvents)) { error in
                XCTAssertEqual(
                    error as? DecisionCommitmentBlockerValidationError,
                    .invalidEvent)
            }
    }
}

final class DecisionCommitmentBlockerStorageTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_787_010_000)

    func testV29MigratesAdditivelyToBlockerAuthorityAndGraphSchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v29")

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 31)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v31")
            XCTAssertEqual(
                try Set(database.columns(in: "decisionCommitmentBlocker").map(\.name)),
                [
                    "id", "decisionID", "commitmentID", "status", "sourceMeetingID",
                    "sourceTranscriptRevision", "primarySegmentID", "confirmedAt",
                    "updatedAt", "latestEventID", "deletedAt"
                ])
            XCTAssertEqual(
                try Set(database.columns(in: "decisionCommitmentBlockerEvent").map(\.name)),
                [
                    "id", "blockerID", "kind", "sourceMeetingID",
                    "sourceTranscriptRevision", "primarySegmentID", "occurredAt"
                ])
            XCTAssertEqual(
                try Set(database.columns(
                    in: "meetingMemoryGraphDecisionCommitmentBlocker").map(\.name)),
                ["blockerID", "decisionID", "commitmentID"])
            XCTAssertTrue(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testBlockerRoundTripsTransitionsAndServesOnlyCurrentAuthority() async throws {
        let fixture = try await seededFixture()
        let blockerID = DecisionCommitmentBlockerID()
        let evidence = fixture.evidence(segmentIDs: fixture.segments.map(\.id))
        let confirmation = DecisionCommitmentBlockerConfirmation(
            blockerID: blockerID,
            decisionID: fixture.decisionID,
            commitmentID: fixture.commitmentID,
            evidence: evidence,
            confirmedAt: Self.baseDate.addingTimeInterval(10))

        let opened = try await ConfirmDecisionCommitmentBlocker(store: fixture.store)
            .execute(confirmation)
        XCTAssertEqual(opened.blocker.status, .active)
        XCTAssertEqual(opened.openingEvidence.segmentIDs, fixture.segments.map(\.id))
        let active = try await fixture.store.activeDecisionCommitmentBlockers(
            for: fixture.commitmentID)
        let openingReplay = try await fixture.store.confirmDecisionCommitmentBlocker(
            confirmation)
        XCTAssertEqual(active, [opened])
        XCTAssertEqual(openingReplay, opened)

        await assertBlockerThrows {
            _ = try await fixture.store.confirmDecisionCommitmentBlocker(
                DecisionCommitmentBlockerConfirmation(
                    decisionID: fixture.decisionID,
                    commitmentID: fixture.commitmentID,
                    evidence: evidence,
                    confirmedAt: Self.baseDate.addingTimeInterval(11)))
        }

        let clearID = DecisionCommitmentBlockerEventID()
        let cleared = try await ManageDecisionCommitmentBlocker(store: fixture.store)
            .execute(DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                eventID: clearID,
                transition: .clear,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[1].id]),
                confirmedAt: Self.baseDate))
        XCTAssertEqual(cleared.blocker.status, .cleared)
        XCTAssertGreaterThan(cleared.events[0].occurredAt, opened.blocker.updatedAt)
        let activeAfterClear = try await fixture.store.activeDecisionCommitmentBlockers(
            for: fixture.commitmentID)
        XCTAssertTrue(activeAfterClear.isEmpty)

        let replay = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                eventID: clearID,
                transition: .clear,
                evidence: cleared.events[0].evidence,
                confirmedAt: Self.baseDate))
        XCTAssertEqual(replay, cleared)

        let reopened = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                transition: .reopen,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[0].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(30)))
        XCTAssertEqual(reopened.blocker.status, .active)
        XCTAssertEqual(reopened.events.map(\.kind), [.clear, .reopen])
        let replayAfterReopen = try await fixture.store
            .applyDecisionCommitmentBlockerTransition(DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                eventID: clearID,
                transition: .clear,
                evidence: cleared.events[0].evidence,
                confirmedAt: cleared.events[0].occurredAt))
        XCTAssertEqual(replayAfterReopen, reopened)
    }

    func testStaleDuplicateAndCorrectedEvidenceRollBackAtomically() async throws {
        let fixture = try await seededFixture()
        let invalidEvidence = [
            fixture.evidence(
                revision: fixture.meeting.transcriptRevision + 1,
                segmentIDs: [fixture.segments[0].id]),
            fixture.evidence(segmentIDs: [fixture.segments[0].id, fixture.segments[0].id]),
            fixture.evidence(segmentIDs: [UUID()])
        ]
        for evidence in invalidEvidence {
            await assertBlockerThrows {
                _ = try await fixture.store.confirmDecisionCommitmentBlocker(
                    DecisionCommitmentBlockerConfirmation(
                        decisionID: fixture.decisionID,
                        commitmentID: fixture.commitmentID,
                        evidence: evidence))
            }
        }
        let count = try await blockerCount(in: fixture.store)
        XCTAssertEqual(count, 0)

        let blockerID = DecisionCommitmentBlockerID()
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: blockerID,
                decisionID: fixture.decisionID,
                commitmentID: fixture.commitmentID,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[1].id])))
        _ = try await fixture.store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id,
            baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: [fixture.segments[0].id],
            kind: .replaceText(text: "The launch remains blocked.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: Self.baseDate.addingTimeInterval(20)))

        await assertBlockerThrows {
            _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
                DecisionBlockerTransitionConfirmation(
                    blockerID: blockerID,
                    transition: .clear,
                    evidence: fixture.evidence(segmentIDs: [fixture.segments[0].id])))
        }
        let unchanged = try await fixture.store.decisionCommitmentBlockerContinuity(
            for: blockerID)
        XCTAssertEqual(unchanged.blocker.status, .active)
        XCTAssertTrue(unchanged.events.isEmpty)
    }

    func testReopenAndActiveServingRequireLiveConfirmedEndpoints() async throws {
        let fixture = try await seededFixture()
        let blockerID = DecisionCommitmentBlockerID()
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: blockerID,
                decisionID: fixture.decisionID,
                commitmentID: fixture.commitmentID,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[0].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(10)))
        _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                transition: .clear,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[1].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(20)))
        _ = try await fixture.store.applyCommitmentTransition(
            .complete,
            to: fixture.commitmentID,
            at: Self.baseDate.addingTimeInterval(30))

        await assertBlockerThrows {
            _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
                DecisionBlockerTransitionConfirmation(
                    blockerID: blockerID,
                    transition: .reopen,
                    evidence: fixture.evidence(segmentIDs: [fixture.segments[0].id]),
                    confirmedAt: Self.baseDate.addingTimeInterval(40)))
        }
        let active = try await fixture.store.activeDecisionCommitmentBlockers(
            for: fixture.commitmentID)
        XCTAssertTrue(active.isEmpty)
    }

    func testDatabaseTriggersRejectInvalidProjectionAndMutableHistory() async throws {
        let fixture = try await seededFixture()
        let blockerID = DecisionCommitmentBlockerID()
        let evidence = fixture.evidence(segmentIDs: [fixture.segments[0].id])
        let blocker = try DecisionCommitmentBlockerPolicy.projectedBlocker(
            id: blockerID,
            decisionID: fixture.decisionID,
            commitmentID: fixture.commitmentID,
            openingEvidence: evidence,
            confirmedAt: Self.baseDate.addingTimeInterval(10),
            events: [])
        try await fixture.store.database.write { database in
            var invalid = try DecisionCommitmentBlockerRecord(
                blocker: blocker,
                openingEvidence: evidence)
            invalid.primarySegmentID = UUID().uuidString
            XCTAssertThrowsError(try invalid.insert(database))
        }

        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: blockerID,
                decisionID: fixture.decisionID,
                commitmentID: fixture.commitmentID,
                evidence: evidence,
                confirmedAt: blocker.confirmedAt))
        try await fixture.store.database.write { database in
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE decisionCommitmentBlocker SET status = 'cleared' WHERE id = ?",
                arguments: [blockerID.rawValue.uuidString]))
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE decisionCommitmentBlocker SET decisionID = ? WHERE id = ?",
                arguments: [DecisionID().rawValue.uuidString, blockerID.rawValue.uuidString]))
            XCTAssertThrowsError(try DecisionCommitmentBlockerEventRecord(
                DecisionCommitmentBlockerEvent(
                    blockerID: blockerID,
                    kind: .reopen,
                    evidence: evidence,
                    occurredAt: blocker.confirmedAt.addingTimeInterval(1)))
                .insert(database))
        }
    }

    private func seededFixture() async throws -> BlockerFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Launch blocker review", startedAt: Self.baseDate)
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The security decision blocks the release notes.",
                language: "en",
                startTime: 1,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Seguridad confirmó que el bloqueo quedó resuelto.",
                language: "es",
                startTime: 3,
                endTime: 4,
                isFinal: true)
        ]
        try await store.database.write { database in
            try MeetingRecord(
                meeting,
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate)
                .insert(database)
            for segment in segments {
                try SegmentRecord(
                    segment,
                    createdAt: Self.baseDate,
                    updatedAt: Self.baseDate)
                    .insert(database)
            }
        }
        let decisionID = DecisionID()
        try await insertDecision(
            id: decisionID,
            meeting: meeting,
            segmentID: segments[0].id,
            in: store)
        let commitment = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare release notes",
                origin: .manual(meetingID: meeting.id)),
            at: Self.baseDate.addingTimeInterval(2))
        return BlockerFixture(
            store: store,
            meeting: meeting,
            segments: segments,
            decisionID: decisionID,
            commitmentID: commitment.commitment.id)
    }

    private func insertDecision(
        id: DecisionID,
        meeting: Meeting,
        segmentID: UUID,
        in store: MeetingStore
    ) async throws {
        let sourceID = DecisionSourceID()
        let source = DecisionSource(
            id: sourceID,
            decisionID: id,
            observationID: SummaryDecisionID(),
            summaryID: SummaryID(),
            meetingID: meeting.id,
            observedStatement: "Security approval is required.",
            sourceTranscriptRevision: meeting.transcriptRevision,
            observedAt: meeting.startedAt,
            linkedAt: Self.baseDate.addingTimeInterval(1),
            evidence: [DecisionEvidenceSegment(segmentID: segmentID, ordinal: 0)],
            availability: .current)
        let event = DecisionEvent(
            decisionID: id,
            kind: .confirm,
            sourceID: sourceID,
            occurredAt: Self.baseDate.addingTimeInterval(1))
        try await store.database.write { database in
            try DecisionContinuityRecord(MeetingDecision(
                id: id,
                statement: "Security approval is required.",
                status: .confirmed,
                createdAt: event.occurredAt,
                updatedAt: event.occurredAt))
                .insert(database)
            try DecisionContinuitySourceRecord(source).insert(database)
            try DecisionContinuityEvidenceSegmentRecord(
                sourceID: sourceID,
                evidence: source.evidence[0])
                .insert(database)
            try DecisionContinuityEventRecord(event).insert(database)
        }
    }

    private func blockerCount(in store: MeetingStore) async throws -> Int {
        try await store.database.read { database in
            try DecisionCommitmentBlockerRecord.fetchCount(database)
        }
    }
}

private struct BlockerFixture {
    let store: MeetingStore
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let decisionID: DecisionID
    let commitmentID: CommitmentID

    func evidence(
        revision: Int? = nil,
        segmentIDs: [UUID]
    ) -> DecisionCommitmentBlockerEvidence {
        DecisionCommitmentBlockerEvidence(
            meetingID: meeting.id,
            sourceTranscriptRevision: revision ?? meeting.transcriptRevision,
            segmentIDs: segmentIDs)
    }
}

private func assertBlockerThrows(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
