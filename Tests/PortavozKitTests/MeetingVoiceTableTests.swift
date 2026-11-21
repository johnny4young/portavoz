import PortavozCore
import XCTest

@testable import ApplicationKit

final class MeetingVoiceTableTests: XCTestCase {
    private let meeting = MeetingID()

    func testRowsFollowTheCastByTalkShareWithTheirOwnTurns() {
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let marta = Speaker(meetingID: meeting, label: "S1", displayName: "Marta")
        let silent = Speaker(meetingID: meeting, label: "S2")
        let segments = [
            segment(marta.id, 0, 4),
            segment(me.id, 14.1, 14.3),
            segment(marta.id, 30, 36),
            segment(me.id, 18.8, 21),
            segment(nil, 40, 41)
        ]
        let cast = VoiceCast(speakers: [me, marta, silent], segments: segments)

        let table = MeetingVoiceTable(cast: cast, segments: segments, meetingLength: 60)

        XCTAssertEqual(table.rows.map(\.speakerID), [marta.id, me.id], "a voice that never spoke has no row")
        XCTAssertTrue(table.others.isEmpty)
        XCTAssertEqual(table.rows.last?.turns, [14.1...14.3, 18.8...21], "turns come sorted by start")
        XCTAssertEqual(table.rows.first?.voice.talkSeconds, 10)
        XCTAssertEqual(table.duration, 60)
    }

    func testTwelveVoicesKeepSixRowsAndFoldTheRestByTalkShare() {
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let remotes = (1...11).map { Speaker(meetingID: meeting, label: "S\($0)", displayName: "Voice \($0)") }
        var start: TimeInterval = 0
        var segments = [segment(me.id, 0, 1)]
        for (index, speaker) in remotes.enumerated() {
            start += 10
            segments.append(segment(speaker.id, start, start + Double(20 - index)))
        }
        let cast = VoiceCast(speakers: [me] + remotes, segments: segments)

        let table = MeetingVoiceTable(cast: cast, segments: segments)

        XCTAssertEqual(table.rows.count, 6)
        XCTAssertEqual(table.others.map(\.speakerID), Array(remotes.suffix(6).map(\.id)))
        XCTAssertEqual(table.count, 12)
        XCTAssertEqual(table.othersShare, table.others.map(\.voice.share).reduce(0, +), accuracy: 1e-9)
        XCTAssertEqual(table.othersTalkSeconds, 15 + 14 + 13 + 12 + 11 + 10)
        XCTAssertTrue(table.others.allSatisfy { $0.voice.tint == .grey })
        XCTAssertEqual(table.duration, 120, "the axis stretches to the last turn without a length")
    }

    func testSteppingWalksTheTurnsAndWrapsToTheFirst() throws {
        let speaker = Speaker(meetingID: meeting, label: "S1", displayName: "Nora")
        let segments = [segment(speaker.id, 5, 8), segment(speaker.id, 20, 25), segment(speaker.id, 40, 42)]
        let table = MeetingVoiceTable(
            cast: VoiceCast(speakers: [speaker], segments: segments), segments: segments)
        let row = try XCTUnwrap(table.rows.first)

        XCTAssertEqual(row.nextTurn(after: -.infinity), 5)
        XCTAssertEqual(row.nextTurn(after: 5), 20, "standing on a turn moves to the next one")
        XCTAssertEqual(row.nextTurn(after: 19), 20)
        XCTAssertEqual(row.nextTurn(after: 19.8), 40, "a seek that landed just short of a turn is on it")
        XCTAssertEqual(row.nextTurn(after: 20.2), 40)
        XCTAssertEqual(row.nextTurn(after: 41), 5, "after the last turn it wraps")
    }

    func testAMeetingWithoutAttributedSpeechHasNoRows() {
        let table = MeetingVoiceTable(
            cast: VoiceCast(members: [], ordering: .talkShare), segments: [segment(nil, 0, 3)])

        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.duration, 0)
    }

    private func segment(_ speaker: SpeakerID?, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting, speakerID: speaker, channel: .system, text: "x",
            startTime: start, endTime: end, isFinal: true)
    }
}
