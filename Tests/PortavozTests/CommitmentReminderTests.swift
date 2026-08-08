import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentReminderPolicyTests: XCTestCase {
    private let commitmentID = CommitmentID()
    private let dueAt = Date(timeIntervalSince1970: 1_802_217_600)
    private let baseDate = Date(timeIntervalSince1970: 1_801_872_000)

    func testReminderLifecycleKeepsSnoozeSeparateFromCommitmentDueDate() throws {
        let schedule = try event(
            .schedule(
                scheduledFor: baseDate.addingTimeInterval(60),
                sourceDueAt: dueAt),
            state: nil,
            at: baseDate)
        let scheduled = try CommitmentReminderPolicy.applying(schedule, to: nil)
        XCTAssertEqual(scheduled.status, .scheduled)
        XCTAssertEqual(scheduled.sourceDueAt, dueAt)

        let present = try event(
            .present,
            state: scheduled,
            at: baseDate.addingTimeInterval(60))
        let presented = try CommitmentReminderPolicy.applying(present, to: scheduled)
        XCTAssertEqual(presented.status, .presented)

        let snoozeDate = baseDate.addingTimeInterval(660)
        let snooze = try event(
            .snooze(until: snoozeDate),
            state: presented,
            at: baseDate.addingTimeInterval(61))
        let snoozed = try CommitmentReminderPolicy.applying(snooze, to: presented)
        XCTAssertEqual(snoozed.status, .scheduled)
        XCTAssertEqual(snoozed.scheduledFor, snoozeDate)
        XCTAssertEqual(snoozed.sourceDueAt, dueAt)

        let secondPresent = try event(
            .present,
            state: snoozed,
            at: snoozeDate)
        let presentedAgain = try CommitmentReminderPolicy.applying(
            secondPresent,
            to: snoozed)
        let dismiss = try event(
            .dismiss,
            state: presentedAgain,
            at: snoozeDate.addingTimeInterval(1))
        let dismissed = try CommitmentReminderPolicy.applying(
            dismiss,
            to: presentedAgain)
        XCTAssertEqual(dismissed.status, .dismissed)
        XCTAssertNil(dismissed.scheduledFor)
        XCTAssertNil(dismissed.sourceDueAt)

        XCTAssertEqual(
            try CommitmentReminderPolicy.projectedState(
                commitmentID: commitmentID,
                events: [schedule, present, snooze, secondPresent, dismiss]),
            dismissed)
    }

    func testReminderPolicyRejectsInvalidPayloadAndLifecycle() throws {
        let malformed = CommitmentReminderEvent(
            commitmentID: commitmentID,
            previousEventID: nil,
            kind: .schedule,
            scheduledFor: nil,
            sourceDueAt: dueAt,
            occurredAt: baseDate)
        XCTAssertThrowsError(
            try CommitmentReminderPolicy.applying(malformed, to: nil)) { error in
                XCTAssertEqual(
                    error as? CommitmentReminderValidationError,
                    .invalidEvent(malformed.id))
            }

        let schedule = try event(
            .schedule(
                scheduledFor: baseDate.addingTimeInterval(60),
                sourceDueAt: dueAt),
            state: nil,
            at: baseDate)
        let state = try CommitmentReminderPolicy.applying(schedule, to: nil)
        let duplicateSchedule = try event(
            .schedule(
                scheduledFor: baseDate.addingTimeInterval(120),
                sourceDueAt: dueAt),
            state: state,
            at: baseDate.addingTimeInterval(1))
        XCTAssertThrowsError(
            try CommitmentReminderPolicy.applying(duplicateSchedule, to: state)) { error in
                XCTAssertEqual(
                    error as? CommitmentReminderValidationError,
                    .invalidLifecycle(duplicateSchedule.id))
            }

        XCTAssertThrowsError(try CommitmentReminderPolicy.event(
            commitmentID: commitmentID,
            previousState: nil,
            transition: .snooze(until: baseDate.addingTimeInterval(120)),
            occurredAt: baseDate))
    }

    private func event(
        _ transition: CommitmentReminderTransition,
        state: CommitmentReminderState?,
        at date: Date
    ) throws -> CommitmentReminderEvent {
        try CommitmentReminderPolicy.event(
            commitmentID: commitmentID,
            previousState: state,
            transition: transition,
            occurredAt: date)
    }
}

final class CommitmentReminderStorageTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_801_872_000)

    func testV23AddsEmptyReminderHistoryWithoutInventingDeliveries() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v22")
        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 33)
            XCTAssertEqual(
                try Set(database.columns(in: "commitmentReminderEvent").map(\.name)),
                Set([
                    "id", "commitmentID", "previousEventID", "kind",
                    "scheduledFor", "sourceDueAt", "occurredAt",
                ]))
            XCTAssertEqual(
                try Set(database.columns(in: "commitmentReminderState").map(\.name)),
                Set([
                    "commitmentID", "status", "latestEventID", "scheduledFor",
                    "sourceDueAt", "createdAt", "updatedAt",
                ]))
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM commitmentReminderEvent"),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM commitmentReminderState"),
                0)
        }
    }

    func testV23RejectsCrossCommitmentOrMutableReminderHistory() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database)
        let firstID = CommitmentID()
        let secondID = CommitmentID()
        let dueAt = baseDate.addingTimeInterval(86_400)
        let firstEvent = CommitmentReminderEvent(
            commitmentID: firstID,
            previousEventID: nil,
            kind: .schedule,
            scheduledFor: baseDate.addingTimeInterval(3_600),
            sourceDueAt: dueAt,
            occurredAt: baseDate)

        try database.write { database in
            for id in [firstID, secondID] {
                try CommitmentRecord(Commitment(
                    id: id,
                    title: "Confirmed work",
                    dueAt: dueAt,
                    createdAt: baseDate))
                    .insert(database)
            }
            try CommitmentReminderEventRecord(firstEvent).insert(database)
            let crossed = CommitmentReminderEvent(
                commitmentID: secondID,
                previousEventID: firstEvent.id,
                kind: .schedule,
                scheduledFor: baseDate.addingTimeInterval(7_200),
                sourceDueAt: dueAt,
                occurredAt: baseDate.addingTimeInterval(1))
            XCTAssertThrowsError(
                try CommitmentReminderEventRecord(crossed).insert(database))
            XCTAssertThrowsError(try database.execute(
                sql: "UPDATE commitmentReminderEvent SET kind = 'cancel' WHERE id = ?",
                arguments: [firstEvent.id.rawValue.uuidString]))
        }
    }

    func testStoragePersistsOneAtomicReminderTimelineWithoutChangingDueDate() async throws {
        let store = try MeetingStore.inMemory()
        let dueAt = baseDate.addingTimeInterval(86_400)
        let commitment = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Send the launch report",
                assignee: .me,
                dueAt: dueAt,
                origin: .manual(meetingID: nil)),
            at: baseDate)
        let reminderDate = baseDate.addingTimeInterval(3_600)

        let scheduled = try await store.applyCommitmentReminderTransition(
            .schedule(scheduledFor: reminderDate, sourceDueAt: dueAt),
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(1))
        let presented = try await store.applyCommitmentReminderTransition(
            .present,
            to: commitment.commitment.id,
            at: reminderDate)
        let snoozeDate = reminderDate.addingTimeInterval(600)
        let snoozed = try await store.applyCommitmentReminderTransition(
            .snooze(until: snoozeDate),
            to: commitment.commitment.id,
            at: reminderDate.addingTimeInterval(1))

        XCTAssertEqual(scheduled.status, .scheduled)
        XCTAssertEqual(presented.status, .presented)
        XCTAssertEqual(snoozed.status, .scheduled)
        XCTAssertEqual(snoozed.scheduledFor, snoozeDate)
        XCTAssertEqual(snoozed.sourceDueAt, dueAt)
        let storedState = try await store.commitmentReminderState(
            for: commitment.commitment.id)
        XCTAssertEqual(storedState, snoozed)
        let history = try await store.commitmentReminderHistory(
            for: commitment.commitment.id)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present, .snooze])
        XCTAssertEqual(history[1].previousEventID, history[0].id)
        XCTAssertEqual(history[2].previousEventID, history[1].id)
        let continuity = try await store.commitmentContinuityEnvelope(
            for: commitment.commitment.id)
        XCTAssertEqual(continuity.commitment.dueAt, dueAt)
    }

    func testStaleOrCompletedCommitmentCannotPresentOrScheduleReminder() async throws {
        let store = try MeetingStore.inMemory()
        let dueAt = baseDate.addingTimeInterval(86_400)
        let envelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Review the migration",
                dueAt: dueAt,
                origin: .manual(meetingID: nil)),
            at: baseDate)
        let commitmentID = envelope.commitment.id
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(
                scheduledFor: baseDate.addingTimeInterval(3_600),
                sourceDueAt: dueAt),
            to: commitmentID,
            at: baseDate.addingTimeInterval(1))
        _ = try await store.applyCommitmentTransition(
            .reschedule(dueAt.addingTimeInterval(86_400)),
            to: commitmentID,
            at: baseDate.addingTimeInterval(2))

        await XCTAssertThrowsErrorAsync(try await store.applyCommitmentReminderTransition(
            .present,
            to: commitmentID,
            at: baseDate.addingTimeInterval(3_600)))
        let unchangedHistory = try await store.commitmentReminderHistory(
            for: commitmentID)
        XCTAssertEqual(unchangedHistory.count, 1)

        let cancelled = try await store.applyCommitmentReminderTransition(
            .cancel,
            to: commitmentID,
            at: baseDate.addingTimeInterval(3))
        XCTAssertEqual(cancelled.status, .cancelled)

        _ = try await store.applyCommitmentTransition(
            .complete,
            to: commitmentID,
            at: baseDate.addingTimeInterval(4))
        await XCTAssertThrowsErrorAsync(try await store.applyCommitmentReminderTransition(
            .schedule(
                scheduledFor: baseDate.addingTimeInterval(7_200),
                sourceDueAt: dueAt.addingTimeInterval(86_400)),
            to: commitmentID,
            at: baseDate.addingTimeInterval(5)))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {}
}
