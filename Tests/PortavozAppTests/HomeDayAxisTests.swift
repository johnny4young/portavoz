import Foundation
import XCTest

@testable import portavoz_app

final class HomeDayAxisTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        return calendar
    }

    private var day: DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        return DateInterval(start: start, duration: 24 * 3_600)
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        day.start.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    private func layout(
        now: Date, recorded: [DayAxisLayout.Item] = [], upcoming: [DayAxisLayout.Item] = [],
        width: CGFloat = 1_200
    ) -> DayAxisLayout {
        DayAxisLayout(
            day: day, now: now, recorded: recorded, upcoming: upcoming, width: width, calendar: calendar)
    }

    func testRangeRoundsToWholeHoursAndPadsHalfAnHour() {
        let axis = layout(
            now: at(12, 20),
            recorded: [.init(start: at(9, 10), duration: 40 * 60)],
            upcoming: [.init(start: at(15, 30), end: at(16, 15))])
        XCTAssertEqual(axis.axisStart, at(8, 30))
        XCTAssertEqual(axis.axisEnd, at(17, 30))
        XCTAssertEqual(axis.x(at(8, 30)), 0)
        XCTAssertEqual(axis.x(at(13)), 600, accuracy: 0.001)
        XCTAssertEqual(axis.x(at(17, 30)), 1_200, accuracy: 0.001)
    }

    func testAnExactHourIsNotRoundedFurther() {
        let axis = layout(now: at(10), upcoming: [.init(start: at(16), end: at(17))])
        XCTAssertEqual(axis.axisStart, at(9, 30))
        XCTAssertEqual(axis.axisEnd, at(17, 30))
    }

    func testAShortDayStillSpansFiveHours() {
        let axis = layout(now: at(10, 20), recorded: [.init(start: at(9, 10), duration: 30 * 60)])
        XCTAssertEqual(axis.axisStart, at(8, 30))
        XCTAssertEqual(axis.axisEnd, at(13, 30))
        XCTAssertEqual(axis.ticks.map(\.date), [at(9), at(10), at(11), at(12), at(13)])
    }

    func testAMeetingFromBeforeTheDayIsClippedToTheLeftEdge() {
        let early = day.start.addingTimeInterval(-3_600)
        let axis = layout(now: at(2), recorded: [.init(start: early, duration: 2 * 3_600)])
        XCTAssertEqual(axis.axisStart, day.start.addingTimeInterval(-30 * 60))
        XCTAssertEqual(axis.recorded[0].x, 0)
        XCTAssertEqual(axis.recorded[0].width, axis.x(at(1)), accuracy: 0.001)
    }

    func testShortItemsKeepAMinimumWidth() {
        let axis = layout(
            now: at(12),
            recorded: [.init(start: at(9), duration: 5)],
            upcoming: [.init(start: at(15), end: at(15))])
        XCTAssertEqual(axis.recorded[0].width, DayAxisLayout.minimumRecordedWidth)
        XCTAssertEqual(axis.upcoming[0].width, DayAxisLayout.minimumUpcomingWidth)
    }

    func testHourLabelsThinOutAsTheAxisNarrows() {
        let items = [DayAxisLayout.Item(start: at(8), end: at(18))]
        // 08:00–18:00 pads to an 11 h span.
        func labeled(_ width: CGFloat) -> [Date] {
            layout(now: at(12), upcoming: items, width: width).ticks.filter(\.labeled).map(\.date)
        }
        let hours = (8...18).map { at($0) }
        XCTAssertEqual(layout(now: at(12), upcoming: items, width: 200).ticks.map(\.date), hours)
        XCTAssertEqual(labeled(11 * 56), hours)
        XCTAssertEqual(labeled(11 * 55), stride(from: 8, through: 18, by: 2).map { at($0) })
        XCTAssertEqual(labeled(11 * 28), stride(from: 8, through: 18, by: 2).map { at($0) })
        XCTAssertEqual(labeled(11 * 27), stride(from: 8, through: 18, by: 3).map { at($0) })
    }

    func testTitleStopsBeforeTheNextMeeting() {
        let axis = layout(
            now: at(8),
            upcoming: [.init(start: at(9), end: at(9, 30)), .init(start: at(10), end: at(11))])
        XCTAssertEqual(
            axis.upcoming[0].titleWidth,
            axis.upcoming[1].x - DayAxisLayout.titleGap - axis.upcoming[0].x, accuracy: 0.001)
        XCTAssertEqual(axis.upcoming[1].titleWidth, 1_200 - axis.upcoming[1].x, accuracy: 0.001)
    }

    func testTitleStopsBeforeTheNowPill() throws {
        let axis = layout(
            now: at(11),
            recorded: [.init(start: at(9), duration: 1_800), .init(start: at(10, 30), duration: 300)],
            upcoming: [.init(start: at(14), end: at(15))])
        let nowX = try XCTUnwrap(axis.nowX)
        XCTAssertEqual(
            axis.recorded[0].titleWidth,
            axis.recorded[1].x - DayAxisLayout.titleGap - axis.recorded[0].x, accuracy: 0.001,
            "the next meeting is nearer than now")
        XCTAssertEqual(
            axis.recorded[1].titleWidth,
            nowX - DayAxisLayout.nowClearance - axis.recorded[1].x, accuracy: 0.001)
        XCTAssertEqual(
            axis.upcoming[0].titleWidth, 1_200 - axis.upcoming[0].x, accuracy: 0.001,
            "a meeting ahead of now is not held back by the pill")

        let underThePill = layout(now: at(11), recorded: [.init(start: at(10, 55), duration: 300)])
        XCTAssertEqual(underThePill.recorded[0].titleWidth, 0)
    }

    func testNowSitsOnTheAxisOnlyInsideTheRange() throws {
        let inside = layout(now: at(11), upcoming: [.init(start: at(14), end: at(15))])
        XCTAssertEqual(try XCTUnwrap(inside.nowX), inside.x(at(11)), accuracy: 0.001)

        let before = layout(
            now: day.start.addingTimeInterval(-2 * 3_600),
            upcoming: [.init(start: at(1), end: at(2))])
        XCTAssertEqual(before.axisStart, day.start.addingTimeInterval(-30 * 60))
        XCTAssertNil(before.nowX)
    }

    func testAZeroWidthAxisStaysFinite() {
        let axis = layout(now: at(11), recorded: [.init(start: at(9), duration: 1_800)], width: 0)
        XCTAssertEqual(axis.recorded[0].x, 0)
        XCTAssertEqual(axis.recorded[0].titleWidth, 0)
        XCTAssertEqual(axis.nowX, 0)
    }

    func testTalkDurationShowsWholeMinutesAndHours() {
        XCTAssertEqual(TalkDuration.text(0), "0 min")
        XCTAssertEqual(TalkDuration.text(20), "1 min")
        XCTAssertEqual(TalkDuration.text(44.4 * 60), "44 min")
        XCTAssertEqual(TalkDuration.text(59.6 * 60), "1 h 0 min")
        XCTAssertEqual(TalkDuration.text(106 * 60), "1 h 46 min")
    }

    func testNowShowsTheClockWithoutItsPeriod() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // 2026-09-09 13:08 UTC.
        let date = Date(timeIntervalSince1970: 1_788_959_280)
        func clock(_ id: String) -> String {
            HomeDayAxis.clock(date, locale: Locale(identifier: id), timeZone: utc)
        }
        XCTAssertEqual(clock("en_US"), "1:08", "never 01:08 or 1:08 PM")
        XCTAssertEqual(clock("en_GB"), "13:08")
        XCTAssertEqual(clock("es_CO"), "1:08")
    }
}
