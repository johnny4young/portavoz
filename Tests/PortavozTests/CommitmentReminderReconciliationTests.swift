import ApplicationKit
import Foundation
import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

final class CommitmentReminderReconciliationTests: XCTestCase {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testSchedulesConfirmedDueCommitmentsAndDefersOverdueDelivery() async throws {
        let store = try MeetingStore.inMemory()
        let futureDue = baseDate.addingTimeInterval(600)
        let overdueDue = baseDate.addingTimeInterval(10)
        let future = try await confirm(
            title: "Send launch report",
            dueAt: futureDue,
            store: store)
        let overdue = try await confirm(
            title: "Review incident",
            dueAt: overdueDue,
            store: store)
        _ = try await confirm(
            title: "No deadline",
            dueAt: nil,
            store: store)
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate.addingTimeInterval(100)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest(
            minimumSchedulingDelay: 5))

        XCTAssertEqual(report.scheduledCount, 2)
        XCTAssertEqual(report.replacedCount, 0)
        XCTAssertEqual(report.reassertedCount, 0)
        XCTAssertEqual(report.cancelledCount, 0)
        let upserts = await scheduler.upsertedSchedules()
        XCTAssertEqual(upserts.count, 2)
        XCTAssertEqual(
            upserts.first { $0.commitmentID == future.commitment.id }?.scheduledFor,
            futureDue)
        XCTAssertEqual(
            upserts.first { $0.commitmentID == overdue.commitment.id }?.scheduledFor,
            now.addingTimeInterval(5))
        let futureState = try await store.commitmentReminderState(
            for: future.commitment.id)
        let overdueState = try await store.commitmentReminderState(
            for: overdue.commitment.id)
        XCTAssertEqual(futureState?.sourceDueAt, futureDue)
        XCTAssertEqual(overdueState?.sourceDueAt, overdueDue)
    }

    func testRelaunchReassertsMatchingScheduleWithoutAppendingHistory() async throws {
        let store = try MeetingStore.inMemory()
        let dueAt = baseDate.addingTimeInterval(600)
        let commitment = try await confirm(
            title: "Publish notes",
            dueAt: dueAt,
            store: store)
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(scheduledFor: dueAt, sourceDueAt: dueAt),
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(1))
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate.addingTimeInterval(2)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())

        XCTAssertEqual(report.reassertedCount, 1)
        let upserts = await scheduler.upsertedSchedules()
        XCTAssertEqual(upserts.count, 1)
        let history = try await store.commitmentReminderHistory(
            for: commitment.commitment.id)
        XCTAssertEqual(history.count, 1)
    }

    func testRescheduledCommitmentAtomicallyReplacesActiveReminder() async throws {
        let store = try MeetingStore.inMemory()
        let originalDue = baseDate.addingTimeInterval(600)
        let replacementDue = baseDate.addingTimeInterval(1_200)
        let commitment = try await confirm(
            title: "Ship build",
            dueAt: originalDue,
            store: store)
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(scheduledFor: originalDue, sourceDueAt: originalDue),
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(1))
        _ = try await store.applyCommitmentTransition(
            .reschedule(replacementDue),
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(2))
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate.addingTimeInterval(3)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())

        XCTAssertEqual(report.replacedCount, 1)
        let upserts = await scheduler.upsertedSchedules()
        XCTAssertEqual(upserts.first?.sourceDueAt, replacementDue)
        let state = try await store.commitmentReminderState(
            for: commitment.commitment.id)
        XCTAssertEqual(state?.status, .scheduled)
        XCTAssertEqual(state?.sourceDueAt, replacementDue)
        let history = try await store.commitmentReminderHistory(
            for: commitment.commitment.id)
        XCTAssertEqual(history.map(\.kind), [.schedule, .cancel, .schedule])
    }

    func testCompletedAndDeletedCommitmentsCancelActiveDelivery() async throws {
        let store = try MeetingStore.inMemory()
        let dueAt = baseDate.addingTimeInterval(600)
        let completed = try await confirm(
            title: "Complete review",
            dueAt: dueAt,
            store: store)
        let deleted = try await confirm(
            title: "Retire draft",
            dueAt: dueAt,
            store: store)
        for id in [completed.commitment.id, deleted.commitment.id] {
            _ = try await store.applyCommitmentReminderTransition(
                .schedule(scheduledFor: dueAt, sourceDueAt: dueAt),
                to: id,
                at: baseDate.addingTimeInterval(1))
        }
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: completed.commitment.id,
            at: baseDate.addingTimeInterval(2))
        let deletionDate = baseDate.addingTimeInterval(2)
        let deletedID = deleted.commitment.id.rawValue.uuidString
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE commitment SET deletedAt = ? WHERE id = ?",
                arguments: [deletionDate, deletedID])
        }
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate.addingTimeInterval(3)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())

        XCTAssertEqual(report.cancelledCount, 2)
        let cancellations = await scheduler.cancelledCommitments()
        XCTAssertEqual(Set(cancellations), Set([
            completed.commitment.id,
            deleted.commitment.id
        ]))
        let completedState = try await store.commitmentReminderState(
            for: completed.commitment.id)
        let deletedState = try await store.commitmentReminderState(
            for: deleted.commitment.id)
        XCTAssertEqual(completedState?.status, .cancelled)
        XCTAssertEqual(deletedState?.status, .cancelled)
    }

    func testDismissedReminderIsNeverSilentlyRearmed() async throws {
        let store = try MeetingStore.inMemory()
        let dueAt = baseDate.addingTimeInterval(600)
        let commitment = try await confirm(
            title: "Keep explicit dismissal",
            dueAt: dueAt,
            store: store)
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(scheduledFor: dueAt, sourceDueAt: dueAt),
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(1))
        _ = try await store.applyCommitmentReminderTransition(
            .present,
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(2))
        _ = try await store.applyCommitmentReminderTransition(
            .dismiss,
            to: commitment.commitment.id,
            at: baseDate.addingTimeInterval(3))
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate.addingTimeInterval(4)

        let report = try await ReconcileCommitmentReminders(
            reader: store,
            writer: store,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())

        XCTAssertEqual(report.unchangedCount, 0)
        let upserts = await scheduler.upsertedSchedules()
        let cancellations = await scheduler.cancelledCommitments()
        XCTAssertTrue(upserts.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
    }

    func testIncompleteSnapshotFailsBeforeSchedulerMutation() async throws {
        let commitment = Commitment(
            title: "Bounded snapshot",
            dueAt: baseDate.addingTimeInterval(600),
            createdAt: baseDate)
        let reader = StaticReminderReconciliationReader(page:
            CommitmentReminderReconciliationPage(
                items: [CommitmentReminderReconciliationItem(
                    commitment: commitment,
                    reminder: nil)],
                totalCount: 2))
        let writer = NoopReminderTransitionWriter()
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate

        await XCTAssertThrowsErrorAsync(try await ReconcileCommitmentReminders(
            reader: reader,
            writer: writer,
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest())) { error in
            XCTAssertEqual(
                error as? ReconcileCommitmentRemindersError,
                .incompleteSnapshot(expected: 2, actual: 1))
        }
        let upserts = await scheduler.upsertedSchedules()
        XCTAssertTrue(upserts.isEmpty)
    }

    func testInitialPersistenceFailureCompensatesSchedulerRequest() async throws {
        let commitment = Commitment(
            title: "Compensate delivery",
            dueAt: baseDate.addingTimeInterval(600),
            createdAt: baseDate)
        let reader = StaticReminderReconciliationReader(page:
            CommitmentReminderReconciliationPage(
                items: [CommitmentReminderReconciliationItem(
                    commitment: commitment,
                    reminder: nil)],
                totalCount: 1))
        let scheduler = RecordingCommitmentReminderScheduler()
        let now = baseDate

        await XCTAssertThrowsErrorAsync(try await ReconcileCommitmentReminders(
            reader: reader,
            writer: FailingReminderTransitionWriter(),
            scheduler: scheduler,
            now: { now }
        ).execute(ReconcileCommitmentRemindersRequest()))

        let upserts = await scheduler.upsertedSchedules()
        let cancellations = await scheduler.cancelledCommitments()
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(cancellations, [commitment.id])
    }

    private func confirm(
        title: String,
        dueAt: Date?,
        store: MeetingStore
    ) async throws -> CommitmentContinuityEnvelope {
        try await store.confirmCommitment(
            CommitmentConfirmation(
                title: title,
                assignee: .me,
                dueAt: dueAt,
                origin: .manual(meetingID: nil)),
            at: baseDate)
    }
}

private actor RecordingCommitmentReminderScheduler: CommitmentReminderDeliveryScheduling {
    private var upserts: [CommitmentReminderDeliverySchedule] = []
    private var cancellations: [CommitmentID] = []

    func upsertCommitmentReminder(
        _ schedule: CommitmentReminderDeliverySchedule
    ) {
        upserts.append(schedule)
    }

    func cancelCommitmentReminder(for commitmentID: CommitmentID) {
        cancellations.append(commitmentID)
    }

    func upsertedSchedules() -> [CommitmentReminderDeliverySchedule] { upserts }
    func cancelledCommitments() -> [CommitmentID] { cancellations }
}

private struct StaticReminderReconciliationReader:
    CommitmentReminderReconciliationReading
{
    let page: CommitmentReminderReconciliationPage

    func commitmentReminderReconciliationPage(
        _: CommitmentReminderReconciliationQuery
    ) async throws -> CommitmentReminderReconciliationPage {
        page
    }
}

private struct NoopReminderTransitionWriter: CommitmentReminderTransitionWriting {
    func applyCommitmentReminderTransition(
        _: CommitmentReminderTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState {
        CommitmentReminderState(
            commitmentID: commitmentID,
            status: .cancelled,
            latestEventID: eventID,
            scheduledFor: nil,
            sourceDueAt: nil,
            createdAt: proposedDate,
            updatedAt: proposedDate)
    }

    func replaceCommitmentReminderSchedule(
        scheduledFor: Date,
        sourceDueAt: Date,
        commitmentID: CommitmentID,
        cancellationEventID: CommitmentReminderEventID,
        scheduleEventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState {
        CommitmentReminderState(
            commitmentID: commitmentID,
            status: .scheduled,
            latestEventID: scheduleEventID,
            scheduledFor: scheduledFor,
            sourceDueAt: sourceDueAt,
            createdAt: proposedDate,
            updatedAt: proposedDate)
    }
}

private struct FailingReminderTransitionWriter: CommitmentReminderTransitionWriting {
    enum Failure: Error { case rejected }

    func applyCommitmentReminderTransition(
        _: CommitmentReminderTransition,
        to _: CommitmentID,
        eventID _: CommitmentReminderEventID,
        at _: Date
    ) async throws -> CommitmentReminderState {
        throw Failure.rejected
    }

    func replaceCommitmentReminderSchedule(
        scheduledFor _: Date,
        sourceDueAt _: Date,
        commitmentID _: CommitmentID,
        cancellationEventID _: CommitmentReminderEventID,
        scheduleEventID _: CommitmentReminderEventID,
        at _: Date
    ) async throws -> CommitmentReminderState {
        throw Failure.rejected
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
