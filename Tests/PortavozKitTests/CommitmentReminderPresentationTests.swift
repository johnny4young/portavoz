import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class CommitmentReminderPresentationTests: XCTestCase {
    private let baseDate = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testRecordsExactScheduledDeliveryOnce() async throws {
        let fixture = try await scheduledFixture()
        let deliveredAt = fixture.scheduledFor.addingTimeInterval(2)
        let useCase = RecordCommitmentReminderPresentation(
            repository: fixture.store)
        let request = request(fixture, deliveredAt: deliveredAt)

        let firstOutcome = try await useCase.execute(request)
        let repeatedOutcome = try await useCase.execute(request)
        XCTAssertEqual(firstOutcome, .recorded)
        XCTAssertEqual(repeatedOutcome, .alreadyRecorded)

        let state = try await fixture.store.commitmentReminderState(
            for: fixture.commitmentID)
        XCTAssertEqual(state?.status, .presented)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present])
    }

    func testIgnoresReplacedOrTerminalNotificationIdentity() async throws {
        let fixture = try await scheduledFixture()
        let useCase = RecordCommitmentReminderPresentation(
            repository: fixture.store)
        let stale = ReminderPresentationRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor.addingTimeInterval(-60),
            sourceDueAt: fixture.sourceDueAt.addingTimeInterval(-60),
            deliveredAt: fixture.scheduledFor)

        let replacedOutcome = try await useCase.execute(stale)
        XCTAssertEqual(replacedOutcome, .ignoredStaleDelivery)

        _ = try await fixture.store.applyCommitmentReminderTransition(
            .cancel,
            to: fixture.commitmentID,
            at: fixture.scheduledFor.addingTimeInterval(1))
        let terminalOutcome = try await useCase.execute(request(
            fixture,
            deliveredAt: fixture.scheduledFor.addingTimeInterval(2)))
        XCTAssertEqual(terminalOutcome, .ignoredStaleDelivery)
    }

    func testRejectsMalformedDeliveryChronology() async throws {
        let fixture = try await scheduledFixture()
        let useCase = RecordCommitmentReminderPresentation(
            repository: fixture.store)

        do {
            _ = try await useCase.execute(request(
                fixture,
                deliveredAt: fixture.scheduledFor.addingTimeInterval(-1)))
            XCTFail("Expected invalid delivery chronology to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ReminderPresentationError,
                .invalidDelivery)
        }
    }

    func testConcurrentPresentationRecoversFromThePersistedWinner() async throws {
        let fixture = try await scheduledFixture()
        let repository = PresentationRaceRepository(store: fixture.store)

        let outcome = try await RecordCommitmentReminderPresentation(
            repository: repository
        ).execute(request(
            fixture,
            deliveredAt: fixture.scheduledFor.addingTimeInterval(2)))

        XCTAssertEqual(outcome, .alreadyRecorded)
        let state = try await fixture.store.commitmentReminderState(
            for: fixture.commitmentID)
        XCTAssertEqual(state?.status, .presented)
        let history = try await fixture.store.commitmentReminderHistory(
            for: fixture.commitmentID)
        XCTAssertEqual(history.map(\.kind), [.schedule, .present])
    }
}

private extension CommitmentReminderPresentationTests {
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
        let scheduledFor = sourceDueAt
        _ = try await store.applyCommitmentReminderTransition(
            .schedule(
                scheduledFor: scheduledFor,
                sourceDueAt: sourceDueAt),
            to: confirmation.commitment.id,
            at: baseDate.addingTimeInterval(1))
        return Fixture(
            store: store,
            commitmentID: confirmation.commitment.id,
            scheduledFor: scheduledFor,
            sourceDueAt: sourceDueAt)
    }

    func request(
        _ fixture: Fixture,
        deliveredAt: Date
    ) -> ReminderPresentationRequest {
        ReminderPresentationRequest(
            commitmentID: fixture.commitmentID,
            scheduledFor: fixture.scheduledFor,
            sourceDueAt: fixture.sourceDueAt,
            deliveredAt: deliveredAt)
    }
}

private actor PresentationRaceRepository:
    CommitmentReminderPresentationRepository {
    private let store: MeetingStore
    private var simulatesConcurrentWinner = true

    init(store: MeetingStore) {
        self.store = store
    }

    func commitmentReminderState(
        for commitmentID: CommitmentID
    ) async throws -> CommitmentReminderState? {
        try await store.commitmentReminderState(for: commitmentID)
    }

    func applyCommitmentReminderTransition(
        _ transition: CommitmentReminderTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState {
        let state = try await store.applyCommitmentReminderTransition(
            transition,
            to: commitmentID,
            eventID: eventID,
            at: proposedDate)
        if simulatesConcurrentWinner {
            simulatesConcurrentWinner = false
            throw PresentationRaceError.concurrentWriterWon
        }
        return state
    }
}

private enum PresentationRaceError: Error {
    case concurrentWriterWon
}
