import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class MeetingReminderWorkflowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_500_000)

    func testDisabledReminderDoesNotReadCalendar() async throws {
        let listing = UpcomingMeetingListingFake(events: [event("Soon", minutes: 2)])

        let result = try await ResolveMeetingReminder(meetings: listing).execute(
            request(leadMinutes: 0))

        XCTAssertNil(result)
        let callCount = await listing.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testEarliestDueEventAndMinutesUseOneSampledTime() async throws {
        let listing = UpcomingMeetingListingFake(events: [
            event("Later", minutes: 4.2),
            event("Sooner", minutes: 2.1),
        ])

        let result = try await ResolveMeetingReminder(meetings: listing).execute(
            request(leadMinutes: 5))

        XCTAssertEqual(result?.event.title, "Sooner")
        XCTAssertEqual(result?.minutesUntilStart, 3)
    }

    func testStartedAndOutOfWindowEventsProduceNoNotice() async throws {
        let listing = UpcomingMeetingListingFake(events: [
            event("Started", minutes: -1),
            event("Later", minutes: 10),
        ])

        let result = try await ResolveMeetingReminder(meetings: listing).execute(
            request(leadMinutes: 5))

        XCTAssertNil(result)
    }

    func testAlreadyRemindedEventIsNotReturnedAgain() async throws {
        let due = event("Soon", minutes: 2)
        let listing = UpcomingMeetingListingFake(events: [due])

        let result = try await ResolveMeetingReminder(meetings: listing).execute(
            request(leadMinutes: 5, alreadyReminded: [due.id]))

        XCTAssertNil(result)
    }

    func testCalendarFailurePropagates() async {
        let listing = UpcomingMeetingListingFake(error: ReminderWorkflowTestError.failed)

        do {
            _ = try await ResolveMeetingReminder(meetings: listing).execute(
                request(leadMinutes: 5))
            XCTFail("expected calendar failure")
        } catch {
            XCTAssertEqual(error as? ReminderWorkflowTestError, .failed)
        }
    }

    private func request(
        leadMinutes: Int,
        alreadyReminded: Set<String> = []
    ) -> MeetingReminderRequest {
        MeetingReminderRequest(
            now: now,
            leadMinutes: leadMinutes,
            alreadyReminded: alreadyReminded)
    }

    private func event(_ title: String, minutes: Double) -> UpcomingEvent {
        UpcomingEvent(
            title: title,
            startDate: now.addingTimeInterval(minutes * 60),
            attendees: [])
    }
}

private enum ReminderWorkflowTestError: Error, Equatable {
    case failed
}

private actor UpcomingMeetingListingFake: UpcomingMeetingListing {
    private(set) var callCount = 0
    let events: [UpcomingEvent]
    let error: ReminderWorkflowTestError?

    init(
        events: [UpcomingEvent] = [],
        error: ReminderWorkflowTestError? = nil
    ) {
        self.events = events
        self.error = error
    }

    func upcomingMeetings() async throws -> [UpcomingEvent] {
        callCount += 1
        if let error { throw error }
        return events
    }
}
