import XCTest

@testable import portavoz_app

final class MeetingDetailPrimaryColumnTests: XCTestCase {
    func testOnlyCombinedHeightPressureSelectsFocusedReading() {
        XCTAssertTrue(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 392, playerHeight: 166))
        XCTAssertTrue(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 526 - 1, playerHeight: 166))
        XCTAssertFalse(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 526, playerHeight: 166))
        XCTAssertFalse(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 600, playerHeight: 166))
        XCTAssertFalse(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 392, playerHeight: 0),
            "meetings without a player retain the simultaneous reading layout")
    }
}
