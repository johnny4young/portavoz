import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingVoicesTableFormatTests: XCTestCase {
    func testOthersSummaryNamesThreeAndCountsTheRest() {
        XCTAssertEqual(VoicesTableFormat.summary(["Elena", "Bruno"]), "Elena, Bruno")
        XCTAssertEqual(VoicesTableFormat.summary(["Elena", "Bruno", "S9"]), "Elena, Bruno, S9")
        XCTAssertEqual(VoicesTableFormat.summary(["Elena", "Bruno", "S9", "Pablo", "S11"]), "Elena, Bruno, S9 +2")
    }

    func testRowsNameYouThenTheSpeakerThenTheirLabel() {
        let meeting = MeetingID()
        XCTAssertEqual(
            VoiceName.of(Speaker(meetingID: meeting, label: "Me", isMe: true)),
            L10n.text("You"))
        XCTAssertEqual(
            VoiceName.of(Speaker(meetingID: meeting, label: "S1", displayName: "Marta")), "Marta")
        XCTAssertEqual(VoiceName.of(Speaker(meetingID: meeting, label: "S3")), "S3")
    }
}
