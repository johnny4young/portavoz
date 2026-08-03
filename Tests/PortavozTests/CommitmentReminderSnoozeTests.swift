import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class CommitmentReminderSnoozeTests: XCTestCase {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 2_500_000)

    func testSnoozeRecordsPresentationAndKeepsCommitmentDueDate() async throws {
        let fixture = try await scheduledFixture()
        let request = snoozeRequest(fixture)

        let outcome = try await SnoozeCommitmentReminder(
            repository: fixture.store
        ).execute(request)

        XCTAssertEqual(outcome, .snoozed(until: request.snoozeUntil))
        let reminder = try await fixture.store.commitmentReminderState(
            for: fixture.commitmentID)
        XCTAssertEqual(reminder?.status, .scheduled)
        XCTAssertEqual(reminder?.scheduledFor, request.snoozeUntil)
        XCTAssertEqual(reminder?.sourceDueAt, fixture.sourceDueAt)
        let commitment = try await fixture.store.commitmentRadar(
            try CommitmentRadarQuery(
                dayStart: baseDate,
                dueSoonEnd: baseDate.addingTimeInterval(86_400),
                newSince: baseDate.addingTimeInterval(-86_400),
                itemLimit: 10))
            .items.first?.commitment
        XCTAssertEqual(commitment?.dueAt, fixture.sourceDueAt)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present, .snooze])
    }

    func testRepeatedSnoozeResponseIsAnIdempotentStaleNoOp() async throws {
        let fixture = try await scheduledFixture()
        let request = snoozeRequest(fixture)
        let useCase = SnoozeCommitmentReminder(repository: fixture.store)

        let firstOutcome = try await useCase.execute(request)
        let repeatedOutcome = try await useCase.execute(request)
        XCTAssertEqual(firstOutcome, .snoozed(until: request.snoozeUntil))
        XCTAssertEqual(repeatedOutcome, .ignoredStaleDelivery)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present, .snooze])
    }

    func testSnoozeRejectsReplacedDeliveryIdentity() async throws {
        let fixture = try await scheduledFixture()
        let request = ReminderSnoozeRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor.addingTimeInterval(-60),
            sourceDueAt: fixture.sourceDueAt,
            deliveredAt: fixture.scheduledFor,
            handledAt: fixture.scheduledFor.addingTimeInterval(1),
            snoozeUntil: fixture.scheduledFor.addingTimeInterval(901))

        let outcome = try await SnoozeCommitmentReminder(
            repository: fixture.store
        ).execute(request)

        XCTAssertEqual(outcome, .ignoredStaleDelivery)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule])
    }

    func testSnoozeRejectsMalformedChronology() async throws {
        let fixture = try await scheduledFixture()
        let request = snoozeRequest(fixture)
        let malformed = ReminderSnoozeRequest(
            commitmentID: request.commitmentID,
            scheduledFor: request.scheduledFor,
            sourceDueAt: request.sourceDueAt,
            deliveredAt: request.deliveredAt,
            handledAt: request.handledAt,
            snoozeUntil: request.handledAt)

        do {
            _ = try await SnoozeCommitmentReminder(
                repository: fixture.store
            ).execute(malformed)
            XCTFail("Expected malformed snooze chronology to fail")
        } catch {
            XCTAssertEqual(error as? ReminderSnoozeError, .invalidChronology)
        }
    }
}

private extension CommitmentReminderSnoozeTests {
    struct Fixture {
        let store: MeetingStore
        let commitmentID: CommitmentID
        let scheduledFor: Date
        let sourceDueAt: Date
    }

    func scheduledFixture() async throws -> Fixture {
        let store = try MeetingStore.inMemory()
        let sourceDueAt = baseDate.addingTimeInterval(600)
        let confirmation = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Review private reminder",
                assignee: .me,
                dueAt: sourceDueAt,
                origin: .manual(meetingID: nil)),
            at: baseDate)
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(
                scheduledFor: sourceDueAt,
                sourceDueAt: sourceDueAt),
            to: confirmation.commitment.id,
            at: baseDate.addingTimeInterval(1))
        return Fixture(
            store: store,
            commitmentID: confirmation.commitment.id,
            scheduledFor: sourceDueAt,
            sourceDueAt: sourceDueAt)
    }

    func snoozeRequest(_ fixture: Fixture) -> ReminderSnoozeRequest {
        let deliveredAt = fixture.scheduledFor.addingTimeInterval(2)
        let handledAt = deliveredAt.addingTimeInterval(1)
        return ReminderSnoozeRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor,
            sourceDueAt: fixture.sourceDueAt,
            deliveredAt: deliveredAt,
            handledAt: handledAt,
            snoozeUntil: handledAt.addingTimeInterval(900))
    }
}
