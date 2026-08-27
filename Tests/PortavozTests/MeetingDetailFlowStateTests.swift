import ApplicationKit
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class MeetingDetailFlowStateTests: XCTestCase {
    func testRenameMeetingOwnsDraftAndReplacesTheActiveSheetRoute() async {
        let flow = MeetingDetailFlowState()
        flow.sheet = .recap

        flow.presentRenameMeeting(title: "Weekly planning")

        XCTAssertEqual(flow.sheet?.id, "renameMeeting")
        XCTAssertEqual(flow.renameMeetingTitle, "Weekly planning")
    }

    func testEachPresentationLaneKeepsAtMostOneActiveRoute() async {
        let flow = MeetingDetailFlowState()

        flow.sheet = .recap
        flow.sheet = .newStructure
        flow.dialog = .publishGist
        flow.alert = .failure("offline")

        XCTAssertEqual(flow.sheet?.id, "newStructure")
        XCTAssertEqual(flow.dialog?.id, "publish-gist")
        XCTAssertEqual(flow.alert?.id, "failure")
    }

    func testRenameSpeakerCapturesTheSpeakerAndPrefillsItsName() async {
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

    func testPresentingAnotherSpeakerReplacesTheRenamePayloadAndDraft() async {
        let flow = MeetingDetailFlowState()
        let meetingID = MeetingID()
        let first = Speaker(meetingID: meetingID, label: "S1", displayName: "Ana")
        let second = Speaker(meetingID: meetingID, label: "S2")

        flow.presentRenameSpeaker(first)
        flow.presentRenameSpeaker(second)

        XCTAssertEqual(flow.renamingSpeaker?.id, second.id)
        XCTAssertEqual(flow.renameSpeakerName, "")
    }

    func testMirrorProjectionRequiresOptInCurrentMeetingAndConversationSignal() async {
        let detail = makeMirrorDetail(duration: 600, includeRemoteSpeaker: true)

        XCTAssertNil(MeetingDetailMirrorValues.qualifying(
            detail: detail,
            enabled: false,
            justRecorded: detail.meeting.id,
            language: "en",
            averageShare: nil))
        XCTAssertNil(MeetingDetailMirrorValues.qualifying(
            detail: detail,
            enabled: true,
            justRecorded: MeetingID(),
            language: "en",
            averageShare: nil))

        let values = MeetingDetailMirrorValues.qualifying(
            detail: detail,
            enabled: true,
            justRecorded: detail.meeting.id,
            language: "es",
            averageShare: 0.42)

        XCTAssertNotNil(values)
        XCTAssertEqual(values?.language, "es")
        XCTAssertEqual(values?.averageShare, 0.42)
    }

    func testMirrorProjectionRejectsShortOrSingleSpeakerRecordings() async {
        let short = makeMirrorDetail(duration: 120, includeRemoteSpeaker: true)
        let solo = makeMirrorDetail(duration: 600, includeRemoteSpeaker: false)

        for detail in [short, solo] {
            XCTAssertNil(MeetingDetailMirrorValues.qualifying(
                detail: detail,
                enabled: true,
                justRecorded: detail.meeting.id,
                language: "en",
                averageShare: nil))
        }
    }

    func testPlaybackNavigationFocusesComposedEvidenceBeforePlaybackExists() async {
        let meetingID = MeetingID()
        let sourceID = UUID()
        let rowID = UUID()
        let segment = TranscriptSegment(
            id: sourceID,
            meetingID: meetingID,
            channel: .system,
            text: "Evidence",
            startTime: 12,
            endTime: 14,
            isFinal: true)
        let content = MeetingTranscriptContent(
            baseTranscriptRevision: 4,
            rows: [MeetingTranscriptContent.Row(
                id: rowID,
                sourceSegmentIDs: [sourceID],
                speakerID: nil,
                channel: .system,
                text: segment.text,
                language: "en",
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: nil,
                isFinal: true)],
            chapters: [])
        let navigation = MeetingDetailPlaybackNavigation()

        navigation.focusEvidence(segment, content: content, player: nil)

        XCTAssertEqual(navigation.focusedRowID, rowID)
    }

    private func makeMirrorDetail(
        duration: TimeInterval,
        includeRemoteSpeaker: Bool
    ) -> MeetingReviewReadModel {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let meeting = Meeting(
            title: "Weekly review",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration))
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let remote = Speaker(meetingID: meeting.id, label: "S1")
        var speakers = [me]
        var segments = [TranscriptSegment(
            meetingID: meeting.id,
            speakerID: me.id,
            channel: .microphone,
            text: "I will review the current state.",
            startTime: 0,
            endTime: 30,
            isFinal: true)]
        if includeRemoteSpeaker {
            speakers.append(remote)
            segments.append(TranscriptSegment(
                meetingID: meeting.id,
                speakerID: remote.id,
                channel: .system,
                text: "Here is the external perspective.",
                startTime: 40,
                endTime: 80,
                isFinal: true))
        }
        return MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: speakers,
                segments: segments),
            summary: nil,
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])
    }
}
