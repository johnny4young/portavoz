import XCTest
@testable import portavoz_app

final class MeetingRowTitleTests: XCTestCase {
    func testStripsLeadingISODate() {
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 Sprint Demo · Zephyr"), "Sprint Demo · Zephyr")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10   Sync"), "Sync")
    }

    func testStripsTheDefaultTemplatesTime() {
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 10.47 Meeting"), "Meeting")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 10.47"), "10.47")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 10.5 release"), "10.5 release")
        XCTAssertEqual(MeetingRowTitle.display("10.47 Meeting"), "10.47 Meeting")
    }

    func testLeavesOtherTitlesAlone() {
        XCTAssertEqual(MeetingRowTitle.display("Test meeting"), "Test meeting")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10"), "2026-07-10")
        XCTAssertEqual(MeetingRowTitle.display("2026-07-10 "), "2026-07-10 ")
        XCTAssertEqual(MeetingRowTitle.display("10-07-2026 Sync"), "10-07-2026 Sync")
        XCTAssertEqual(MeetingRowTitle.display(""), "")
    }
}
