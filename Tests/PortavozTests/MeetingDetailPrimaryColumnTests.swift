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

    func testMeetingWithAudioChoosesItsLayoutBeforePlaybackRenders() {
        for column: CGFloat in [392, 525] {
            let pending = MeetingDetailPrimaryColumnLayout.usesFocusedPane(
                columnHeight: column, playerHeight: 0, expectsPlayer: true)
            let rendered = MeetingDetailPrimaryColumnLayout.usesFocusedPane(
                columnHeight: column, playerHeight: 166, expectsPlayer: true)
            XCTAssertTrue(pending, "the first frame must not show both panes and then switch")
            XCTAssertEqual(pending, rendered)
        }
        XCTAssertFalse(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 526, playerHeight: 0, expectsPlayer: true))
        XCTAssertTrue(MeetingDetailPrimaryColumnLayout.usesFocusedPane(
            columnHeight: 600, playerHeight: 260, expectsPlayer: true),
            "a taller measured dock still wins over the reservation")
    }
}
