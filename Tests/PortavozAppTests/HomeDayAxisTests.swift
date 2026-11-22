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

    private func title(_ full: CGFloat, word: CGFloat = 40, minutes: CGFloat = 30) -> DayAxisLayout.Title {
        DayAxisLayout.Title(full: full, word: word, minutes: minutes)
    }

    private func assertApart(_ frames: [DayAxisLayout.Frame], file: StaticString = #filePath, line: UInt = #line) {
        let shown = frames.filter { $0.fit != .hidden }.sorted { $0.titleX < $1.titleX }
        for (left, right) in zip(shown, shown.dropFirst()) {
            XCTAssertLessThanOrEqual(
                left.titleX + left.titleWidth, right.titleX - DayAxisLayout.titleGap + 0.001, file: file, line: line)
        }
    }

    func testTitlesSitAtTheirMeetingsWhenThereIsRoom() {
        let axis = layout(
            now: at(8),
            upcoming: [
                .init(start: at(9), end: at(9, 30), title: title(100)),
                .init(start: at(10), end: at(11), title: title(100))
            ])
        for frame in axis.upcoming {
            XCTAssertEqual(frame.fit, .full)
            XCTAssertEqual(frame.titleX, frame.x, accuracy: 0.001)
            XCTAssertEqual(frame.titleWidth, 100)
        }
    }

    func testACrowdedTitleEndsBeforeTheNextAndExtendsLeft() {
        let axis = layout(
            now: at(8),
            upcoming: [
                .init(start: at(9), end: at(9, 10), title: title(120)),
                .init(start: at(9, 10), end: at(9, 40), title: title(120))
            ])
        XCTAssertEqual(axis.upcoming.map(\.fit), [.full, .full])
        XCTAssertEqual(axis.upcoming[1].titleX, axis.upcoming[1].x, accuracy: 0.001, "the later title keeps its start")
        XCTAssertEqual(
            axis.upcoming[0].titleX + 120, axis.upcoming[1].x - DayAxisLayout.titleGap, accuracy: 0.001,
            "the earlier title ends before it and takes the free space to its left")
        XCTAssertLessThan(axis.upcoming[0].titleX, axis.upcoming[0].x)
    }

    func testAMeetingThatJustEndedKeepsItsWholeTitleBeforeTheNowPill() throws {
        for endedAgo in [2, 10] {
            let end = at(11).addingTimeInterval(TimeInterval(-endedAgo * 60))
            let axis = layout(
                now: at(11),
                recorded: [.init(start: end.addingTimeInterval(-10 * 60), end: end, title: title(150), markWidth: 17)])
            let nowX = try XCTUnwrap(axis.nowX)
            let frame = axis.recorded[0]
            XCTAssertEqual(frame.fit, .full, "ended \(endedAgo) min ago")
            XCTAssertEqual(frame.titleWidth, 150)
            XCTAssertLessThanOrEqual(
                frame.titleX + frame.titleWidth, nowX - DayAxisLayout.nowPillWidth / 2 - DayAxisLayout.titleGap + 0.001,
                "ended \(endedAgo) min ago: the title ends before the pill")
            XCTAssertGreaterThanOrEqual(frame.titleX, 0)
            XCTAssertEqual(frame.x, axis.x(end.addingTimeInterval(-10 * 60)), accuracy: 0.001, "alone, the mark keeps its time")
        }
    }

    func testAWiderNowPillPushesTheTitlesFurtherOut() throws {
        let item = DayAxisLayout.Item(start: at(10, 40), duration: 10 * 60, title: title(150))
        let ahead = DayAxisLayout.Item(start: at(11, 5), end: at(12), title: title(100))
        let axis = DayAxisLayout(
            day: day, now: at(11), recorded: [item], upcoming: [ahead], width: 1_200, nowPillWidth: 140,
            calendar: calendar)
        let nowX = try XCTUnwrap(axis.nowX)
        XCTAssertLessThanOrEqual(
            axis.recorded[0].titleX + axis.recorded[0].titleWidth, nowX - 70 - DayAxisLayout.titleGap + 0.001)
        XCTAssertGreaterThanOrEqual(axis.upcoming[0].titleX, nowX + 70 + DayAxisLayout.titleGap - 0.001)
    }

    func testBackToBackShortMeetingsKeepTheirMarksApartAndBothTitles() throws {
        let axis = layout(
            now: at(11),
            recorded: [
                .init(start: at(10, 30), duration: 5 * 60, title: title(110), markWidth: 40),
                .init(start: at(10, 35), duration: 5 * 60, title: title(110), markWidth: 40)
            ])
        let first = axis.recorded[0]
        let second = axis.recorded[1]
        XCTAssertEqual(first.markWidth, 40, "the dots outgrow a five-minute strip")
        XCTAssertGreaterThanOrEqual(second.x - (first.x + first.markWidth), DayAxisLayout.markGap - 0.001)
        XCTAssertEqual(second.x, axis.x(at(10, 35)), accuracy: 0.001, "the earlier mark gives way, not the later")
        XCTAssertLessThanOrEqual(second.x + second.width, try XCTUnwrap(axis.nowX))
        XCTAssertEqual(second.titleX, second.x, accuracy: 0.001, "each title starts over its own meeting")
        XCTAssertEqual(axis.recorded.map(\.fit), [.full, .truncated])
        assertApart(axis.recorded)
    }

    func testTightTitlesAreCutToAWordThenFallBackToMinutes() {
        let titles = [title(100), title(100)]
        func place(upper: CGFloat) -> [(x: CGFloat, width: CGFloat, fit: DayAxisLayout.Fit)] {
            DayAxisLayout.place(titles, anchors: [0, 60], lows: [0, 50], upper: upper)
        }
        let cut = place(upper: 150)
        XCTAssertEqual(cut.map(\.fit), [.truncated, .truncated])
        XCTAssertEqual(cut[1].x, 60, accuracy: 0.01, "the later title keeps its start")
        XCTAssertEqual(cut[1].x + cut[1].width, 150, accuracy: 0.01, "and every point to the end")
        XCTAssertEqual(cut[0].x, 0, accuracy: 0.01)
        XCTAssertEqual(cut[0].x + cut[0].width, cut[1].x - DayAxisLayout.titleGap, accuracy: 0.01)

        XCTAssertEqual(place(upper: 90).map(\.width), [40, 40], "never narrower than one word and an ellipsis")
        XCTAssertEqual(place(upper: 80).map(\.fit), [.minutes, .minutes])
        XCTAssertEqual(place(upper: 20).map(\.fit), [.hidden, .hidden])
        XCTAssertEqual(
            DayAxisLayout.place([title(100, minutes: 0)], anchors: [0], lows: [0], upper: 30).map(\.fit), [.hidden],
            "an event without minutes has nothing to fall back to")
    }

    func testATitleNeverReachesBackOverThePreviousMeeting() {
        let axis = layout(
            now: at(11),
            recorded: [
                .init(start: at(9), end: at(10, 30), title: title(120), markWidth: 30),
                .init(start: at(10, 40), duration: 5 * 60, title: title(150), markWidth: 17)
            ])
        let long = axis.recorded[0]
        let short = axis.recorded[1]
        XCTAssertGreaterThanOrEqual(short.titleX, long.x + long.markWidth + DayAxisLayout.titleGap - 0.001)
        XCTAssertNotEqual(short.fit, .full, "cut rather than set over the meeting before")
        XCTAssertNotEqual(short.fit, .hidden)
        XCTAssertEqual(long.fit, .full)
        XCTAssertEqual(long.titleX, long.x, accuracy: 0.001)
    }

    func testANarrowAxisDropsATitleRatherThanDrawUnderThePill() {
        let axis = layout(now: at(9, 35), recorded: [.init(start: at(9, 20), duration: 600, title: title(150))], width: 300)
        XCTAssertEqual(axis.recorded[0].fit, .hidden)
        XCTAssertEqual(axis.recorded[0].titleWidth, 0)
    }

    func testMeetingsSharingAStartShowBothTitlesApart() {
        let axis = layout(
            now: at(8),
            upcoming: [
                .init(start: at(15), end: at(16), title: title(100)),
                .init(start: at(15), end: at(15, 30), title: title(100))
            ])
        XCTAssertEqual(axis.upcoming.map(\.fit), [.full, .full])
        assertApart(axis.upcoming)
    }

    func testAMeetingAheadOfNowStartsAfterThePill() throws {
        let axis = layout(
            now: at(11),
            recorded: [.init(start: at(9), duration: 1_800, title: title(120))],
            upcoming: [
                .init(start: at(11, 5), end: at(12), title: title(120)),
                .init(start: at(14), end: at(15), title: title(200))
            ])
        let nowX = try XCTUnwrap(axis.nowX)
        XCTAssertGreaterThanOrEqual(
            axis.upcoming[0].titleX, nowX + DayAxisLayout.nowPillWidth / 2 + DayAxisLayout.titleGap - 0.001,
            "a title starting under the pill moves past it")
        XCTAssertEqual(axis.upcoming[1].titleX, axis.upcoming[1].x, accuracy: 0.001)
        XCTAssertEqual(axis.recorded[0].titleX, axis.recorded[0].x, accuracy: 0.001)
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
        let axis = layout(now: at(11), recorded: [.init(start: at(9), duration: 1_800, title: title(100))], width: 0)
        XCTAssertEqual(axis.recorded[0].x, 0)
        XCTAssertEqual(axis.recorded[0].titleWidth, 0)
        XCTAssertEqual(axis.recorded[0].fit, .hidden)
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
