import Foundation
import PortavozCore
import XCTest

@testable import ApplicationKit

final class LibraryStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wed Jul 8 2026 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_783_512_000)

    private func meeting(daysAgo: Double, minutes: Double = 30) -> Meeting {
        let started = now.addingTimeInterval(-daysAgo * 86_400)
        return Meeting(
            title: "m", startedAt: started,
            endedAt: started.addingTimeInterval(minutes * 60))
    }

    func testTotalsAndAverage() {
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 1, minutes: 30), meeting(daysAgo: 2, minutes: 60)],
            calendar: calendar, now: now)
        XCTAssertEqual(stats.totalMeetings, 2)
        XCTAssertEqual(stats.totalSeconds, 90 * 60)
        XCTAssertEqual(stats.averageSeconds, 45 * 60)
    }

    func testOpenEndedMeetingsCountButDoNotSkewDurations() {
        var open = meeting(daysAgo: 1)
        open.endedAt = nil
        let stats = LibraryStats.compute(
            meetings: [open, meeting(daysAgo: 2, minutes: 40)],
            calendar: calendar, now: now)
        XCTAssertEqual(stats.totalMeetings, 2)
        XCTAssertEqual(stats.averageSeconds, 40 * 60, "open-ended meeting must not drag the average")
    }

    func testWeekBucketsIncludeZeroWeeksAndCoverWindow() {
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 0.5), meeting(daysAgo: 15)],
            weeks: 4, calendar: calendar, now: now)
        XCTAssertEqual(stats.perWeek.count, 4)
        XCTAssertEqual(stats.perWeek.map(\.count).reduce(0, +), 2)
        XCTAssertTrue(stats.perWeek.contains { $0.count == 0 }, "gap weeks must appear as zeros")
        XCTAssertEqual(
            stats.perWeek, stats.perWeek.sorted { $0.weekStart < $1.weekStart },
            "oldest → newest")
    }

    func testStreakCountsConsecutiveWeeksEndingNow()  {
        // Meetings this week and last week, then a gap two weeks before.
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 1), meeting(daysAgo: 8), meeting(daysAgo: 25)],
            weeks: 6, calendar: calendar, now: now)
        XCTAssertEqual(stats.weeklyStreak, 2)
    }

    func testStreakZeroWhenThisWeekIsEmpty() {
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 10)], weeks: 6, calendar: calendar, now: now)
        XCTAssertEqual(stats.weeklyStreak, 0)
    }

    func testBusiestWeekday() {
        // Two meetings on the same weekday beat one on another.
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 0), meeting(daysAgo: 7), meeting(daysAgo: 1)],
            calendar: calendar, now: now)
        // now is a Wednesday (weekday 4 in Gregorian/UTC).
        XCTAssertEqual(stats.busiestWeekday, 4)
    }

    func testEmptyLibrary() {
        let stats = LibraryStats.compute(meetings: [], calendar: calendar, now: now)
        XCTAssertEqual(stats.totalMeetings, 0)
        XCTAssertEqual(stats.averageSeconds, 0)
        XCTAssertEqual(stats.weeklyStreak, 0)
        XCTAssertNil(stats.busiestWeekday)
    }

    func testHeatmapGridAlignsWithBucketsAndCountsWeekdays() {
        // now = Wed Jul 8. Two meetings today (this week), one 7 days ago.
        let stats = LibraryStats.compute(
            meetings: [meeting(daysAgo: 0), meeting(daysAgo: 0), meeting(daysAgo: 7)],
            weeks: 4, calendar: calendar, now: now)
        // One column per bucket, seven weekday rows each.
        XCTAssertEqual(stats.heatmap.count, stats.perWeek.count)
        XCTAssertTrue(stats.heatmap.allSatisfy { $0.count == 7 })
        // Every meeting lands in a cell; the total matches.
        XCTAssertEqual(stats.heatmap.flatMap { $0 }.reduce(0, +), 3)
        // The busiest cell (two meetings on the same Wednesday) is the max.
        XCTAssertEqual(stats.heatmapMax, 2)
        // The newest column (this week) holds the two-meeting Wednesday.
        XCTAssertEqual(stats.heatmap.last?.max(), 2)
    }

    func testHeatmapEmptyLibraryIsAllZeros() {
        let stats = LibraryStats.compute(
            meetings: [], weeks: 4, calendar: calendar, now: now)
        XCTAssertEqual(stats.heatmapMax, 0)
        XCTAssertEqual(stats.heatmap.flatMap { $0 }.reduce(0, +), 0)
    }
}
