import PortavozCore
import XCTest

@testable import portavoz_app

final class MeetingPlaybackVoiceTests: XCTestCase {
    /// Post-capture replaces speaker identities; voices must come from the
    /// transcript the user is looking at, never from when playback loaded.
    func testVoicesCarryTheirTurnsFromTheCurrentTranscriptMeFirst() {
        let meeting = MeetingID()
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let remote = Speaker(meetingID: meeting, label: "S1", displayName: "Brendan")
        let silent = Speaker(meetingID: meeting, label: "S2")
        let segments = [
            segment(meeting, remote.id, 0, 4),
            segment(meeting, me.id, 14.1, 14.3),
            segment(meeting, me.id, 18.8, 21),
            segment(meeting, nil, 30, 31)
        ]

        let voices = MeetingPlaybackVoice.voices(speakers: [remote, silent, me], segments: segments)

        XCTAssertEqual(voices.map(\.label), ["Me", "S1"])
        XCTAssertEqual(voices.map(\.name), ["Me", "Brendan"])
        XCTAssertEqual(voices.first?.turns, [14.1...14.3, 18.8...21])
    }

    private func segment(
        _ meeting: MeetingID, _ speaker: SpeakerID?, _ start: TimeInterval, _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting, speakerID: speaker, channel: .system, text: "x",
            startTime: start, endTime: end, isFinal: true)
    }
}
