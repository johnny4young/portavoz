import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class CommitmentReminderDismissalTests: XCTestCase {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 2_750_000)

    func testDismissalRecordsPresentationAndKeepsCommitmentDueDate() async throws {
        let fixture = try await scheduledFixture()
        let request = dismissalRequest(fixture)

        let outcome = try await DismissCommitmentReminder(
            repository: fixture.store
        ).execute(request)

        XCTAssertEqual(outcome, .dismissed)
        let reminder = try await fixture.store.commitmentReminderState(
            for: fixture.commitmentID)
        XCTAssertEqual(reminder?.status, .dismissed)
        XCTAssertNil(reminder?.scheduledFor)
        XCTAssertNil(reminder?.sourceDueAt)
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
        XCTAssertEqual(history.map(\.kind), [.schedule, .present, .dismiss])
    }

    func testRepeatedDismissalResponseIsAnIdempotentStaleNoOp() async throws {
        let fixture = try await scheduledFixture()
        let request = dismissalRequest(fixture)
        let useCase = DismissCommitmentReminder(repository: fixture.store)

        let firstOutcome = try await useCase.execute(request)
        let repeatedOutcome = try await useCase.execute(request)

        XCTAssertEqual(firstOutcome, .dismissed)
        XCTAssertEqual(repeatedOutcome, .ignoredStaleDelivery)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present, .dismiss])
    }

    func testDismissalRejectsReplacedDeliveryIdentity() async throws {
        let fixture = try await scheduledFixture()
        let request = ReminderDismissalRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor.addingTimeInterval(-60),
            sourceDueAt: fixture.sourceDueAt,
            deliveredAt: fixture.scheduledFor,
            handledAt: fixture.scheduledFor.addingTimeInterval(1))

        let outcome = try await DismissCommitmentReminder(
            repository: fixture.store
        ).execute(request)

        XCTAssertEqual(outcome, .ignoredStaleDelivery)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule])
    }

    func testDismissalRejectsMalformedChronology() async throws {
        let fixture = try await scheduledFixture()
        let request = dismissalRequest(fixture)
        let malformed = ReminderDismissalRequest(
            commitmentID: request.commitmentID,
            scheduledFor: request.scheduledFor,
            sourceDueAt: request.sourceDueAt,
            deliveredAt: request.deliveredAt,
            handledAt: request.deliveredAt.addingTimeInterval(-1))

        do {
            _ = try await DismissCommitmentReminder(
                repository: fixture.store
            ).execute(malformed)
            XCTFail("Expected malformed dismissal chronology to fail")
        } catch {
            XCTAssertEqual(
                error as? ReminderDismissalError,
                .invalidChronology)
        }
    }
}

private extension CommitmentReminderDismissalTests {
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

    func dismissalRequest(_ fixture: Fixture) -> ReminderDismissalRequest {
        let deliveredAt = fixture.scheduledFor.addingTimeInterval(2)
        return ReminderDismissalRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor,
            sourceDueAt: fixture.sourceDueAt,
            deliveredAt: deliveredAt,
            handledAt: deliveredAt.addingTimeInterval(1))
    }
}
