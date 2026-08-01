import Foundation
import XCTest

@testable import portavoz_app

final class MeetingDetailPresentationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testClockFormattingClampsNegativeTimeAndSupportsPaddedMinutes() {
        let presentation = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: utc)

        XCTAssertEqual(presentation.clock(-4), "0:00")
        XCTAssertEqual(presentation.clock(65.4), "1:05")
        XCTAssertEqual(presentation.clock(65.6, paddedMinutes: true), "01:06")
        XCTAssertEqual(presentation.refinedDuration(125), "2:05 min")
    }

    func testMeetingFactsRemainBoundedAndDeterministic() {
        let presentation = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: utc)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(presentation.meetingDuration(startedAt: start, endedAt: nil))
        XCTAssertEqual(
            presentation.meetingDuration(
                startedAt: start,
                endedAt: start.addingTimeInterval(359)),
            "5 min")
        XCTAssertEqual(
            presentation.meetingDuration(
                startedAt: start,
                endedAt: start.addingTimeInterval(-10)),
            "0 min")
        XCTAssertEqual(presentation.segmentCount(-1), "0 segments")
        XCTAssertEqual(presentation.segmentCount(42), "42 segments")
    }

    func testMeetingDateUsesTheInjectedLocaleAndTimeZone() {
        let date = Date(timeIntervalSince1970: 1_704_072_600)
        let english = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US"),
            timeZone: utc)
        let spanish = MeetingDetailPresentation(
            locale: Locale(identifier: "es_ES"),
            timeZone: utc)

        XCTAssertEqual(english.languageIdentifier, "en")
        XCTAssertEqual(spanish.languageIdentifier, "es")
        XCTAssertNotEqual(english.meetingDate(date), spanish.meetingDate(date))
        XCTAssertTrue(english.meetingDate(date).contains("2024"))
        XCTAssertTrue(spanish.meetingDate(date).contains("2024"))

        let losAngeles = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertNotEqual(english.meetingDate(date), losAngeles.meetingDate(date))
        XCTAssertTrue(losAngeles.meetingDate(date).contains("2023"))
        XCTAssertNotEqual(english.shortDate(date), losAngeles.shortDate(date))
    }
}
