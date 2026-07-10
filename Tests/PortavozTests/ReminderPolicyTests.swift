import Foundation
import IntegrationsKit
import XCTest

final class ReminderPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_500_000)

    private func event(_ title: String, inMinutes minutes: Double) -> UpcomingEvent {
        UpcomingEvent(
            title: title,
            startDate: now.addingTimeInterval(minutes * 60),
            attendees: [])
    }

    func testFiresInsideTheLeadWindowOnly() {
        let events = [event("Far", inMinutes: 30), event("Soon", inMinutes: 4)]
        // upcomingEvents() is start-sorted; policy takes the first due one.
        let due = ReminderPolicy.dueEvent(
            events: events.sorted { $0.startDate < $1.startDate },
            now: now, leadMinutes: 5, alreadyReminded: [])
        XCTAssertEqual(due?.title, "Soon")
        XCTAssertNil(
            ReminderPolicy.dueEvent(
                events: [event("Far", inMinutes: 30)],
                now: now, leadMinutes: 5, alreadyReminded: []))
    }

    func testAlreadyStartedAndAlreadyRemindedAreSkipped() {
        let started = event("Started", inMinutes: -2)
        XCTAssertNil(
            ReminderPolicy.dueEvent(
                events: [started], now: now, leadMinutes: 5, alreadyReminded: []))

        let soon = event("Soon", inMinutes: 3)
        XCTAssertNil(
            ReminderPolicy.dueEvent(
                events: [soon], now: now, leadMinutes: 5, alreadyReminded: [soon.id]))
    }

    func testLeadZeroMeansOff() {
        XCTAssertNil(
            ReminderPolicy.dueEvent(
                events: [event("Soon", inMinutes: 1)],
                now: now, leadMinutes: 0, alreadyReminded: []))
    }
}
