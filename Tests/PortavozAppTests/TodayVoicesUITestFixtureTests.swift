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
}
