import XCTest
@testable import portavoz_app

final class TodayVoicesUITestFixtureTests: XCTestCase {
    func testMeetingsKeepLengthJustAfterMidnight() {
        for sinceMidnight: TimeInterval in [60, 24 * 60, 59 * 60] {
            for justEnded in [false, true] {
                let window = AppServices.todayVoicesWindow(sinceMidnight: sinceMidnight, justEnded: justEnded)
                XCTAssertGreaterThan(window.span, 0, "\(sinceMidnight) s, justEnded \(justEnded)")
                XCTAssertLessThanOrEqual(window.quiet + window.span, sinceMidnight, "stays inside today")
                XCTAssertEqual(window.quiet > 0, justEnded)
            }
        }
    }

    func testLaterInTheDayKeepsTheFullQuietGapAndSpan() {
        let nightly = AppServices.todayVoicesWindow(sinceMidnight: (3 * 60 + 23) * 60, justEnded: true)
        XCTAssertEqual(nightly.quiet, 90 * 60)
        let midday = AppServices.todayVoicesWindow(sinceMidnight: 12 * 3_600, justEnded: true)
        XCTAssertEqual(midday.quiet, 90 * 60)
        XCTAssertEqual(midday.span, 4 * 3_600)
    }

    func testAgendaFixturesStayInTheLaunchDayNearMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Bogota"))
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_000_000))
        let latest: TimeInterval = 4.5 * 3_600
        func time(_ offset: TimeInterval, at launch: Date) -> Date {
            AppServices.fixtureTime(offset, latest: latest, launch: launch, calendar: calendar)
        }

        let noon = midnight.addingTimeInterval(12 * 3_600)
        XCTAssertEqual(time(45 * 60, at: noon), noon.addingTimeInterval(45 * 60), "a midday launch keeps its offsets")
        for minutesLeft: TimeInterval in [240, 15, 10, 1] {
            let launch = midnight.addingTimeInterval(24 * 3_600 - minutesLeft * 60)
            let first = time(45 * 60, at: launch), last = time(latest, at: launch)
            XCTAssertTrue(calendar.isDate(last, inSameDayAs: launch), "\(minutesLeft) min left")
            XCTAssertGreaterThanOrEqual(first, launch)
            XCTAssertLessThanOrEqual(first, last, "events keep their order")
        }
    }
}
