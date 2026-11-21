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
            segment(me.id, 40, 42),
            segment(marta.id, 30, 36),
            segment(nil, 40, 41)
        ]
        let cast = VoiceCast(speakers: [me, marta, silent], segments: segments)

        let table = MeetingVoiceTable(cast: cast, segments: segments, meetingLength: 60)

        XCTAssertEqual(table.rows.map(\.speakerID), [marta.id, me.id], "a voice that never spoke has no row")
        XCTAssertTrue(table.others.isEmpty)
        XCTAssertEqual(table.rows.last?.turns, [14.1...14.3, 40...42], "turns come sorted by start")
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
        let other = Speaker(meetingID: meeting, label: "S2", displayName: "Ilarion")
        let segments = [
            segment(speaker.id, 5, 8), segment(other.id, 10, 12), segment(speaker.id, 20, 25),
            segment(other.id, 30, 32), segment(speaker.id, 40, 42)
        ]
        let table = MeetingVoiceTable(
            cast: VoiceCast(speakers: [speaker, other], segments: segments), segments: segments)
        let row = try XCTUnwrap(table.rows.first { $0.speakerID == speaker.id })

        XCTAssertEqual(row.nextTurn(after: -.infinity), 5)
        XCTAssertEqual(row.nextTurn(after: 5), 20, "standing on a turn moves to the next one")
        XCTAssertEqual(row.nextTurn(after: 19.6), 20, "paused just before a turn, the click plays it")
        XCTAssertEqual(row.nextTurn(after: 19.95), 40, "a seek that landed a frame short of a turn is on it")
        XCTAssertEqual(row.nextTurn(after: 20.2), 40)
        XCTAssertEqual(row.nextTurn(after: 41), 5, "after the last turn it wraps")
    }

    func testConsecutiveSegmentsOfOneVoiceAreOneTurnUntilSomeoneElseSpeaks() throws {
        let marta = Speaker(meetingID: meeting, label: "S1", displayName: "Marta")
        let bruno = Speaker(meetingID: meeting, label: "S2", displayName: "Bruno")
        let segments = [
            segment(marta.id, 0, 5), segment(marta.id, 5.5, 9), segment(nil, 9, 10), segment(marta.id, 10, 12),
            segment(bruno.id, 12, 15), segment(marta.id, 15, 18)
        ]
        let table = MeetingVoiceTable(
            cast: VoiceCast(speakers: [marta, bruno], segments: segments), segments: segments)
        let row = try XCTUnwrap(table.rows.first { $0.speakerID == marta.id })

        XCTAssertEqual(row.turns, [0...12, 15...18], "a monologue split into sentences is one turn")
        XCTAssertEqual(row.nextTurn(after: 1), 15, "the next click skips to after Bruno")
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
