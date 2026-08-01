import XCTest
import PortavozCore

@testable import portavoz_app

@MainActor
final class MeetingDetailFlowStateTests: XCTestCase {
    func testRenameMeetingOwnsDraftAndReplacesTheActiveSheetRoute() {
        let flow = MeetingDetailFlowState()
        flow.sheet = .recap

        flow.presentRenameMeeting(title: "Weekly planning")

        XCTAssertEqual(flow.sheet?.id, "renameMeeting")
        XCTAssertEqual(flow.renameMeetingTitle, "Weekly planning")
    }

    func testEachPresentationLaneKeepsAtMostOneActiveRoute() {
        let flow = MeetingDetailFlowState()

        flow.sheet = .recap
        flow.sheet = .newStructure
        flow.dialog = .publishGist
        flow.alert = .failure("offline")

        XCTAssertEqual(flow.sheet?.id, "newStructure")
        XCTAssertEqual(flow.dialog?.id, "publish-gist")
        XCTAssertEqual(flow.alert?.id, "failure")
    }

    func testRenameSpeakerCapturesTheSpeakerAndPrefillsItsName() {
        let flow = MeetingDetailFlowState()
        let speaker = Speaker(
            meetingID: MeetingID(),
            label: "S1",
            displayName: "Ana")

        flow.presentRenameSpeaker(speaker)

        XCTAssertEqual(flow.alert?.id, "rename-speaker")
        XCTAssertEqual(flow.renamingSpeaker?.id, speaker.id)
        XCTAssertEqual(flow.renameSpeakerName, "Ana")
    }

    func testPresentingAnotherSpeakerReplacesTheRenamePayloadAndDraft() {
        let flow = MeetingDetailFlowState()
        let meetingID = MeetingID()
        let first = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        let second = Speaker(meetingID: meetingID, label: "S2")

        flow.presentRenameSpeaker(first)
        flow.presentRenameSpeaker(second)

        XCTAssertEqual(flow.renamingSpeaker?.id, second.id)
        XCTAssertEqual(flow.renameSpeakerName, "")
    }
}
