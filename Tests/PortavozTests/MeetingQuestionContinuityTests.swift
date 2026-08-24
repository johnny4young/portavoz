import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingQuestionContinuityPolicyTests: XCTestCase {
    private let openedAt = Date(timeIntervalSince1970: 1_786_800_000)

    func testProjectionRequiresExactEvidenceAndLegalLifecycle() throws {
        let questionID = MeetingQuestionID()
        let evidence = MeetingQuestionEvidence(
            meetingID: MeetingID(),
            sourceTranscriptRevision: 2,
            segmentIDs: [UUID()])
        let resolve = MeetingQuestionEvent(
            questionID: questionID,
            kind: .resolve,
            evidence: evidence,
            occurredAt: openedAt.addingTimeInterval(1))
        let reopen = MeetingQuestionEvent(
            questionID: questionID,
            kind: .reopen,
            evidence: evidence,
            occurredAt: openedAt.addingTimeInterval(2))
        let question = try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: questionID,
            topicID: TopicID(),
            text: "  Which retention policy applies?  ",
            openingEvidence: evidence,
            openedAt: openedAt,
            events: [resolve, reopen])

        XCTAssertEqual(question.text, "Which retention policy applies?")
        XCTAssertEqual(question.status, .open)
        XCTAssertEqual(question.updatedAt, reopen.occurredAt)

        XCTAssertThrowsError(try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: questionID,
            topicID: question.topicID,
            text: question.text,
            openingEvidence: evidence,
            openedAt: openedAt,
            events: [reopen])) { error in
                XCTAssertEqual(
                    error as? MeetingQuestionContinuityValidationError,
                    .invalidTransition)
            }
        XCTAssertThrowsError(try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: questionID,
            topicID: question.topicID,
            text: question.text,
            openingEvidence: MeetingQuestionEvidence(
                meetingID: evidence.meetingID,
                sourceTranscriptRevision: 2,
                segmentIDs: []),
            openedAt: openedAt,
            events: []))

        let duplicateID = MeetingQuestionEventID()
        let duplicateEvents = [
            MeetingQuestionEvent(
                id: duplicateID,
                questionID: questionID,
                kind: .resolve,
                evidence: evidence,
                occurredAt: openedAt.addingTimeInterval(1)),
            MeetingQuestionEvent(
                id: duplicateID,
                questionID: questionID,
                kind: .reopen,
                evidence: evidence,
                occurredAt: openedAt.addingTimeInterval(2))
        ]
        XCTAssertThrowsError(try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: questionID,
            topicID: question.topicID,
            text: question.text,
            openingEvidence: evidence,
            openedAt: openedAt,
            events: duplicateEvents)) { error in
                XCTAssertEqual(
                    error as? MeetingQuestionContinuityValidationError,
                    .invalidEvent)
            }
    }
}

final class MeetingQuestionContinuityStorageTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_786_810_000)

    func testV28MigratesAdditivelyToQuestionContinuitySchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v28")

        try migrator.migrate(database)

        try database.read { db in
            XCTAssertEqual(StorageSchema.version, 43)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v43")
            XCTAssertEqual(
                try Set(db.columns(in: "meetingQuestion").map(\.name)),
                [
                    "id", "topicID", "text", "status", "sourceMeetingID",
                    "sourceTranscriptRevision", "primarySegmentID", "openedAt",
                    "updatedAt", "latestEventID", "deletedAt"
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "meetingQuestionEvent").map(\.name)),
                [
                    "id", "questionID", "kind", "sourceMeetingID",
                    "sourceTranscriptRevision", "primarySegmentID", "occurredAt"
                ])
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testExplicitQuestionRoundTripsAndTransitionsAtomically() async throws {
        let fixture = try await seededFixture()
        let questionID = MeetingQuestionID()
        let opening = MeetingQuestionEvidence(
            meetingID: fixture.meeting.id,
            sourceTranscriptRevision: fixture.meeting.transcriptRevision,
            segmentIDs: fixture.segments.map(\.id))
        let confirmation = MeetingQuestionConfirmation(
            questionID: questionID,
            topicID: fixture.topic.id,
            text: "  Which retention policy applies?  ",
            evidence: opening,
            confirmedAt: Self.baseDate.addingTimeInterval(10))

        let opened = try await ConfirmMeetingQuestion(store: fixture.store)
            .execute(confirmation)
        XCTAssertEqual(opened.question.status, .open)
        XCTAssertEqual(opened.question.text, "Which retention policy applies?")
        XCTAssertEqual(opened.openingEvidence.segmentIDs, fixture.segments.map(\.id))
        XCTAssertTrue(opened.events.isEmpty)

        let resolveID = MeetingQuestionEventID()
        let resolved = try await ManageMeetingQuestion(store: fixture.store).execute(
            MeetingQuestionTransitionConfirmation(
                questionID: questionID,
                eventID: resolveID,
                transition: .resolve,
                evidence: MeetingQuestionEvidence(
                    meetingID: fixture.meeting.id,
                    sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                    segmentIDs: [fixture.segments[1].id]),
                confirmedAt: Self.baseDate))
        XCTAssertEqual(resolved.question.status, .resolved)
        XCTAssertEqual(resolved.events.map(\.id), [resolveID])
        XCTAssertGreaterThan(resolved.events[0].occurredAt, opened.question.updatedAt)

        let replay = try await fixture.store.applyMeetingQuestionTransition(
            MeetingQuestionTransitionConfirmation(
                questionID: questionID,
                eventID: resolveID,
                transition: .resolve,
                evidence: resolved.events[0].evidence,
                confirmedAt: Self.baseDate))
        XCTAssertEqual(replay, resolved)

        await assertMeetingQuestionThrows {
            _ = try await fixture.store.applyMeetingQuestionTransition(
                MeetingQuestionTransitionConfirmation(
                    questionID: questionID,
                    eventID: resolveID,
                    transition: .resolve,
                    evidence: resolved.events[0].evidence,
                    confirmedAt: resolved.events[0].occurredAt.addingTimeInterval(1)))
        }

        let reopened = try await fixture.store.applyMeetingQuestionTransition(
            MeetingQuestionTransitionConfirmation(
                questionID: questionID,
                transition: .reopen,
                evidence: MeetingQuestionEvidence(
                    meetingID: fixture.meeting.id,
                    sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                    segmentIDs: [fixture.segments[0].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(30)))
        XCTAssertEqual(reopened.question.status, .open)
        XCTAssertEqual(reopened.events.map(\.kind), [.resolve, .reopen])

        let replayAfterLaterEvent = try await fixture.store.applyMeetingQuestionTransition(
            MeetingQuestionTransitionConfirmation(
                questionID: questionID,
                eventID: resolveID,
                transition: .resolve,
                evidence: resolved.events[0].evidence,
                confirmedAt: resolved.events[0].occurredAt))
        XCTAssertEqual(replayAfterLaterEvent, reopened)
    }

    func testStaleDuplicateAndCorrectedEvidenceRollBackWithoutQuestionRows() async throws {
        let fixture = try await seededFixture()
        let invalidEvidence = [
            MeetingQuestionEvidence(
                meetingID: fixture.meeting.id,
                sourceTranscriptRevision: fixture.meeting.transcriptRevision + 1,
                segmentIDs: [fixture.segments[0].id]),
            MeetingQuestionEvidence(
                meetingID: fixture.meeting.id,
                sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                segmentIDs: [fixture.segments[0].id, fixture.segments[0].id]),
            MeetingQuestionEvidence(
                meetingID: fixture.meeting.id,
                sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                segmentIDs: [UUID()])
        ]
        for evidence in invalidEvidence {
            await assertMeetingQuestionThrows {
                _ = try await fixture.store.confirmMeetingQuestion(
                    MeetingQuestionConfirmation(
                        topicID: fixture.topic.id,
                        text: "What remains open?",
                        evidence: evidence))
            }
        }
        let count = try await fixture.store.database.read { db in
            try MeetingQuestionRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 0)

        let questionID = MeetingQuestionID()
        _ = try await fixture.store.confirmMeetingQuestion(
            MeetingQuestionConfirmation(
                questionID: questionID,
                topicID: fixture.topic.id,
                text: "Is the replacement accepted?",
                evidence: MeetingQuestionEvidence(
                    meetingID: fixture.meeting.id,
                    sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                    segmentIDs: [fixture.segments[1].id])))
        _ = try await fixture.store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.meeting.id,
            baseTranscriptRevision: fixture.meeting.transcriptRevision,
            targetSegmentIDs: [fixture.segments[0].id],
            kind: .replaceText(text: "What remains unresolved?", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: Self.baseDate.addingTimeInterval(5)))
        await assertMeetingQuestionThrows {
            _ = try await fixture.store.applyMeetingQuestionTransition(
                MeetingQuestionTransitionConfirmation(
                    questionID: questionID,
                    transition: .resolve,
                    evidence: MeetingQuestionEvidence(
                        meetingID: fixture.meeting.id,
                        sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                        segmentIDs: [fixture.segments[0].id])))
        }
        let unchanged = try await fixture.store.meetingQuestionContinuity(for: questionID)
        XCTAssertEqual(unchanged.question.status, .open)
        XCTAssertTrue(unchanged.events.isEmpty)
    }

    func testDatabaseTriggersRejectInvalidSourceAndKeepHistoryImmutable() async throws {
        let fixture = try await seededFixture()
        let questionID = MeetingQuestionID()
        let evidence = MeetingQuestionEvidence(
            meetingID: fixture.meeting.id,
            sourceTranscriptRevision: fixture.meeting.transcriptRevision,
            segmentIDs: [fixture.segments[0].id])
        let question = try MeetingQuestionContinuityPolicy.projectedQuestion(
            id: questionID,
            topicID: fixture.topic.id,
            text: "What blocks launch?",
            openingEvidence: evidence,
            openedAt: Self.baseDate.addingTimeInterval(10),
            events: [])

        try await fixture.store.database.write { db in
            var record = try MeetingQuestionRecord(
                question: question,
                openingEvidence: evidence)
            record.primarySegmentID = UUID().uuidString
            XCTAssertThrowsError(try record.insert(db))
        }
        _ = try await fixture.store.confirmMeetingQuestion(
            MeetingQuestionConfirmation(
                questionID: questionID,
                topicID: fixture.topic.id,
                text: question.text,
                evidence: evidence,
                confirmedAt: question.openedAt))
        try await fixture.store.database.write { db in
            XCTAssertThrowsError(try db.execute(
                sql: """
                    UPDATE meetingQuestion
                    SET status = 'resolved', updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Self.baseDate.addingTimeInterval(20), questionID.rawValue.uuidString]))
            XCTAssertThrowsError(try db.execute(
                sql: "UPDATE meetingQuestion SET text = 'Rewritten' WHERE id = ?",
                arguments: [questionID.rawValue.uuidString]))
        }
        let loaded = try await fixture.store.meetingQuestionContinuity(for: questionID)
        XCTAssertEqual(loaded.question.text, question.text)
    }

    private func seededFixture() async throws -> QuestionFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Retention review",
            startedAt: Self.baseDate)
        let topic = Topic(preferredLabel: "Retention policy")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Which retention policy applies?",
                language: "en",
                startTime: 1,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Legal confirmed the policy, so the question is resolved.",
                language: "en",
                startTime: 3,
                endTime: 4,
                isFinal: true)
        ]
        try await store.database.write { db in
            try MeetingRecord(
                meeting,
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate)
                .insert(db)
            for segment in segments {
                try SegmentRecord(
                    segment,
                    createdAt: Self.baseDate,
                    updatedAt: Self.baseDate)
                    .insert(db)
            }
            try TopicRecord(
                topic,
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate)
                .insert(db)
        }
        return QuestionFixture(store: store, meeting: meeting, topic: topic, segments: segments)
    }
}

private struct QuestionFixture {
    let store: MeetingStore
    let meeting: Meeting
    let topic: Topic
    let segments: [TranscriptSegment]
}

private func assertMeetingQuestionThrows(
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
