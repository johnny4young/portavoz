import XCTest
@testable import portavoz_app

final class MeetingRowTitleTests: XCTestCase {
    func testStripsLeadingISODate() {
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 Sprint Demo · Zephyr"), "Sprint Demo · Zephyr")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10   Sync"), "Sync")
    }

    func testLeavesOtherTitlesAlone() {
        XCTAssertEqual(MeetingRowTitle.display("Test meeting"), "Test meeting")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10"), "2026-07-10")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 "), "2026-07-10 ")
        XCTAssertEqual(MeetingRowTitle.display("10-07-2026 Sync"), "10-07-2026 Sync")
        XCTAssertEqual(MeetingRowTitle.display(""), "")
    }
}
