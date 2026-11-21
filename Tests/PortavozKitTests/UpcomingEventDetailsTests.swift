import Foundation
import PortavozCore
import XCTest

final class UpcomingEventDetailsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testDurationComesFromTheEndAndIgnoresAnEndBeforeTheStart() {
        let event = UpcomingEvent(
            id: "e", title: "Sync", startDate: start, attendees: [],
            endDate: start.addingTimeInterval(45 * 60))
        XCTAssertEqual(event.durationMinutes, 45)

        let backwards = UpcomingEvent(
            id: "e", title: "Sync", startDate: start, attendees: [],
            endDate: start.addingTimeInterval(-60))
        XCTAssertNil(backwards.endDate)
        XCTAssertNil(backwards.durationMinutes)
    }

    func testDecodesAnEventEncodedBeforeTheDetailsExisted() throws {
        let json = #"{"id":"e","title":"Sync","startDate":0,"attendees":["Ana"]}"#
        let event = try JSONDecoder().decode(UpcomingEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.attendees, ["Ana"])
        XCTAssertNil(event.endDate)
        XCTAssertNil(event.platform)
        XCTAssertNil(event.recurrence)
    }

    func testDecodingKeepsTheEndRuleAndToleratesUnknownDetails() throws {
        let json = #"{"id":"e","title":"Sync","startDate":100,"endDate":0,"#
            + #""attendees":[],"platform":"slack","recurrence":"fortnightly"}"#
        let event = try JSONDecoder().decode(UpcomingEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.endDate, "an end before the start is dropped, as in init")
        XCTAssertNil(event.platform)
        XCTAssertNil(event.recurrence)
    }

    func testOnlyPreviewedFactsDecideWhetherAPreviewIsStale() {
        let previewed = UpcomingEvent(id: "e", title: "Sync", startDate: start, attendees: ["Ana"])
        let decorated = UpcomingEvent(
            id: "e", title: "Sync", startDate: start, attendees: ["Ana"],
            endDate: start.addingTimeInterval(3_600), platform: .zoom, recurrence: .weekly)
        XCTAssertTrue(decorated.hasSamePreviewFacts(as: previewed))
        let moved = UpcomingEvent(
            id: "e", title: "Sync", startDate: start.addingTimeInterval(60), attendees: ["Ana"])
        XCTAssertFalse(moved.hasSamePreviewFacts(as: previewed))
        let renamed = UpcomingEvent(id: "e", title: "Retro", startDate: start, attendees: ["Ana"])
        XCTAssertFalse(renamed.hasSamePreviewFacts(as: previewed))
    }

    func testDetectsThePlatformFromTheFirstTextThatNamesOne() {
        XCTAssertEqual(
            MeetingPlatform.detect(in: [nil, "https://meet.google.com/abc-defg-hij"]),
            .googleMeet)
        XCTAssertEqual(MeetingPlatform.detect(in: ["Join: https://acme.zoom.us/j/123"]), .zoom)
        XCTAssertEqual(
            MeetingPlatform.detect(in: ["https://teams.microsoft.com/l/x", "zoom.us"]), .teams)
        XCTAssertEqual(MeetingPlatform.detect(in: ["Room 4", "https://Whereby.com/team"]), .whereby)
    }

    func testIgnoresHostsInsideLongerNames() {
        XCTAssertNil(MeetingPlatform.detect(in: ["https://notzoom.us/j/1"]))
        XCTAssertNil(MeetingPlatform.detect(in: ["meet.google.community"]))
        XCTAssertNil(MeetingPlatform.detect(in: [nil, "Conference room B"]))
    }
}
