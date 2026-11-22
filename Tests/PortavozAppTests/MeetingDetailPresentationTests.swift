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
    }

    func testSpokenLanguageUsesItsOwnNameAndSkipsUnknownCodes() {
        XCTAssertEqual(MeetingDetailPresentation.spokenLanguageName("es"), "Español")
        XCTAssertEqual(MeetingDetailPresentation.spokenLanguageName("en"), "English")
        XCTAssertNil(MeetingDetailPresentation.spokenLanguageName(nil))
        XCTAssertNil(MeetingDetailPresentation.spokenLanguageName(""))
    }

    func testMeetingKickerUsesTheInjectedLocaleAndTimeZone() {
        let date = Date(timeIntervalSince1970: 1_704_072_600)
        let english = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US"),
            timeZone: utc)
        let spanish = MeetingDetailPresentation(
            locale: Locale(identifier: "es_ES"),
            timeZone: utc)

        XCTAssertEqual(english.languageIdentifier, "en")
        XCTAssertEqual(spanish.languageIdentifier, "es")
        let end = date.addingTimeInterval(42 * 60)
        XCTAssertEqual(
            english.meetingKicker(startedAt: date, endedAt: end, language: "es"),
            "Mon, Jan 1, 2024 · 1:30\u{202F}AM · 42 min · Español")
        XCTAssertNotEqual(
            english.meetingKicker(startedAt: date, endedAt: end, language: "es"),
            spanish.meetingKicker(startedAt: date, endedAt: end, language: "es"))
        XCTAssertTrue(spanish.meetingKicker(startedAt: date, endedAt: nil, language: nil).contains("2024"))

        let losAngeles = MeetingDetailPresentation(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertTrue(
            losAngeles.meetingKicker(startedAt: date, endedAt: nil, language: nil).contains("2023"))
        XCTAssertNotEqual(english.shortDate(date), losAngeles.shortDate(date))
    }
}
