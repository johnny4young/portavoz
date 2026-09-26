import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class RecordingSpeechPreviewTests: XCTestCase {
    func testAppleRangeRevisionStaysOutOfMeetingEvidenceUntilFinalENAndES() async {
        for (volatile, revised, final) in [
            ("We have two items", "We had two items", "We had two items"),
            ("Tenemos dos puntos", "Teníamos dos puntos", "Teníamos dos puntos")
        ] {
            let controller = RecordingController()
            let meetingID = MeetingID()
            func segment(_ text: String, isFinal: Bool) -> TranscriptSegment {
                TranscriptSegment(meetingID: meetingID, channel: .microphone,
                                  text: text, startTime: 0, endTime: 1,
                                  isFinal: isFinal, liveUpdateMode: .rangeRevision)
            }
            controller.receiveLiveCaption(segment(volatile, isFinal: false))
            let firstPreviewID = controller.speechVolatileByChannel[.microphone]?.id
            XCTAssertTrue(controller.captions.isEmpty)
            XCTAssertEqual(controller.speechVolatileByChannel[.microphone]?.text, volatile)

            controller.receiveLiveCaption(segment(revised, isFinal: false))
            XCTAssertEqual(controller.speechVolatileByChannel[.microphone]?.id, firstPreviewID)
            XCTAssertTrue(controller.captions.isEmpty)

            controller.receiveLiveCaption(segment(final, isFinal: true))
            XCTAssertNil(controller.speechVolatileByChannel[.microphone])
            XCTAssertEqual(controller.captions.map(\.text), [final])
            XCTAssertTrue(controller.translations.isEmpty)
        }
    }

    func testNoiseRevisionWithdrawsTheVisibleMicPreview() async {
        let controller = RecordingController()
        let meetingID = MeetingID()
        controller.receiveLiveCaption(TranscriptSegment(
            meetingID: meetingID, channel: .microphone,
            text: "I will send the notes", startTime: 0, endTime: 1,
            isFinal: false, liveUpdateMode: .rangeRevision))
        XCTAssertNotNil(controller.speechVolatileByChannel[.microphone])
        controller.receiveLiveCaption(TranscriptSegment(
            meetingID: meetingID, channel: .microphone,
            text: "R", startTime: 0, endTime: 1,
            confidence: 0.1, isFinal: false, liveUpdateMode: .rangeRevision))
        XCTAssertTrue(controller.speechVolatileByChannel.isEmpty)
        XCTAssertTrue(controller.captions.isEmpty)
    }

    func testOlderFinalKeepsALaterSystemPreviewUntilItsOwnFinal() async {
        let controller = RecordingController()
        let meetingID = MeetingID()
        func segment(_ text: String, start: Double, final: Bool) -> TranscriptSegment {
            TranscriptSegment(meetingID: meetingID, channel: .system,
                              text: text, startTime: start, endTime: start + 0.4,
                              isFinal: final, liveUpdateMode: .rangeRevision)
        }
        controller.receiveLiveCaption(segment("first provisional", start: 0, final: false))
        controller.receiveLiveCaption(segment("later provisional", start: 1, final: false))
        controller.receiveLiveCaption(segment("first final", start: 0, final: true))
        XCTAssertEqual(controller.speechVolatileByChannel[.system]?.text, "later provisional")
        XCTAssertEqual(controller.captions.map(\.text), ["first final"])
        controller.receiveLiveCaption(segment("later final", start: 1, final: true))
        XCTAssertNil(controller.speechVolatileByChannel[.system])
    }
}
