import Foundation
import XCTest

@testable import IntegrationsKit
@testable import PortavozCore

final class InsightsScopeTests: XCTestCase {
    /// A fixed UTC calendar + reference "now" so the window math is
    /// deterministic. Thursday, 2026-07-16 12:00 UTC.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2  // Monday
        return cal
    }

    private var now: Date {
        DateComponents(
            calendar: calendar, year: 2026, month: 7, day: 16, hour: 12
        ).date!
    }

    private func meeting(_ iso: String, minutes: Double = 30) -> Meeting {
        let parts = iso.split(separator: "-").map { Int($0)! }
        let start = DateComponents(
            calendar: calendar, year: parts[0], month: parts[1], day: parts[2], hour: 10
        ).date!
        return Meeting(
            title: iso, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60))
    }

    func testWeekScopeCountsThisWeekAndDeltaVsLastWeek() {
        // This week (Mon 2026-07-13 … Sun 07-19): two meetings.
        // Last week (07-06 … 07-12): one meeting. Older: ignored.
        let meetings = [
            meeting("2026-07-14"), meeting("2026-07-16"),
            meeting("2026-07-08"),
            meeting("2026-06-01"),
        ]
        let totals = ScopedTotals.compute(
            meetings: meetings, scope: .week, now: now, calendar: calendar)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.previousCount, 1)
        XCTAssertEqual(totals.deltaCount, 1)
    }

    func testMonthScopeCountsThisMonthAndDeltaVsLastMonth() {
        // July: 3 meetings. June: 2. May: ignored for the delta.
        let meetings = [
            meeting("2026-07-02"), meeting("2026-07-14"), meeting("2026-07-16"),
            meeting("2026-06-10"), meeting("2026-06-20"),
            meeting("2026-05-01"),
        ]
        let totals = ScopedTotals.compute(
            meetings: meetings, scope: .month, now: now, calendar: calendar)
        XCTAssertEqual(totals.count, 3)
        XCTAssertEqual(totals.previousCount, 2)
        XCTAssertEqual(totals.deltaCount, 1)
    }

    func testYearScopeCountsThisYearAndDeltaVsLastYear() {
        let meetings = [
            meeting("2026-01-05"), meeting("2026-07-16"),
            meeting("2025-12-30"),
        ]
        let totals = ScopedTotals.compute(
            meetings: meetings, scope: .year, now: now, calendar: calendar)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.previousCount, 1)
    }

    func testAverageOnlyCountsMeetingsWithDuration() {
        let ended = meeting("2026-07-14", minutes: 40)
        let ongoing = Meeting(title: "live", startedAt: meeting("2026-07-15").startedAt)
        let totals = ScopedTotals.compute(
            meetings: [ended, ongoing], scope: .week, now: now, calendar: calendar)
        XCTAssertEqual(totals.count, 2)  // both counted
        XCTAssertEqual(totals.averageSeconds, 40 * 60, accuracy: 0.5)  // only the ended one
    }
}
