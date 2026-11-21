import ApplicationKit
import PortavozCore
import XCTest

final class VoiceColumnsTests: XCTestCase {
    private let silence = VoiceColumns.silence

    private func turn(_ voice: Int, _ start: Double, _ end: Double) -> VoiceColumns.Turn {
        VoiceColumns.Turn(voice: voice, start: start, end: end)
    }

    func testInvalidSizesDrawNothing() {
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 1)], duration: 0, count: 4), [])
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 1)], duration: .nan, count: 4), [])
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 1)], duration: 10, count: 0), [])
    }

    func testNoTurnsIsAllSilence() {
        XCTAssertEqual(VoiceColumns.bin([], duration: 10, count: 3), [silence, silence, silence])
    }

    func testEachColumnTakesItsDominantVoice() {
        let columns = VoiceColumns.bin(
            [turn(0, 0, 6), turn(1, 6, 10), turn(1, 3, 4)], duration: 10, count: 2)
        // Column 0 (0–5): voice 0 has 5 s, voice 1 has 1 s. Column 1: voice 1 has 4 s.
        XCTAssertEqual(columns, [0, 1])
    }

    func testTiesGoToTheLowerVoice() {
        XCTAssertEqual(VoiceColumns.bin([turn(1, 0, 5), turn(0, 5, 10)], duration: 10, count: 1), [0])
    }

    func testColumnsUnderThirtyPercentCoverageAreSilent() {
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 2.9)], duration: 10, count: 1), [silence])
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 3)], duration: 10, count: 1), [0])
    }

    func testTurnsAreClippedToTheMeeting() {
        let columns = VoiceColumns.bin([turn(0, -5, 1), turn(1, 9, 50)], duration: 10, count: 10)
        XCTAssertEqual(columns, [0] + Array(repeating: silence, count: 8) + [1])
    }

    func testInvalidVoicesAreIgnored() {
        XCTAssertEqual(
            VoiceColumns.bin([turn(-1, 0, 10), turn(255, 0, 10)], duration: 10, count: 2),
            [silence, silence])
    }

    func testCountIsCappedAtTheWaveformLimit() {
        XCTAssertEqual(VoiceColumns.bin([turn(0, 0, 1)], duration: 1, count: 5_000).count, 2_000)
        XCTAssertEqual(VoiceColumns.count(forWidth: 300), 150)
        XCTAssertEqual(VoiceColumns.count(forWidth: 1), 1)
        XCTAssertEqual(VoiceColumns.count(forWidth: 10_000), 2_000)
        XCTAssertEqual(VoiceColumns.count(forWidth: 0), 0)
    }

    func testCalmPassFillsALoneColumnBetweenAgreeingNeighbours() {
        XCTAssertEqual(VoiceColumns.calmed([0, 1, 0, 1, 1, silence]), [0, 0, 1, 1, 1, silence])
        XCTAssertEqual(VoiceColumns.calmed([0, 1]), [0, 1])
        let raw = VoiceColumns.bin([turn(0, 0, 4), turn(1, 4, 5), turn(0, 5, 9)], duration: 9, count: 9)
        XCTAssertEqual(raw[4], 1)
        XCTAssertEqual(
            VoiceColumns.calmed(VoiceColumns.bin([turn(0, 0, 4), turn(1, 4, 5), turn(0, 5, 9)], duration: 9, count: 9)),
            Array(repeating: 0, count: 9))
    }

    func testStripIndexesVoicesFirstHeardFirstAndStretchesToTheLastTurn() {
        let strip = VoiceColumns.strip(
            [
                (key: "b", start: 4, end: 10),
                (key: "a", start: 0, end: 4),
                (key: "b", start: 12, end: 14),
                (key: "c", start: 3, end: 3),
                (key: "d", start: .nan, end: 2),
            ],
            duration: 8, count: 7)
        XCTAssertEqual(strip.voices.map(\.key), ["a", "b"])
        XCTAssertEqual(strip.voices.map(\.talkSeconds), [4, 8])
        XCTAssertEqual(strip.voices.map(\.firstHeard), [0, 4])
        XCTAssertEqual(strip.duration, 14)
        XCTAssertEqual(strip.columns, [0, 0, 1, 1, 1, silence, 1])
    }

    func testStripWithoutTurnsHasNoColumns() {
        let strip = VoiceColumns.strip([(key: "a", start: 1, end: 1)], duration: 30, count: 10)
        XCTAssertEqual(strip.columns, [])
        XCTAssertEqual(strip.voices, [])
        XCTAssertEqual(strip.duration, 30)
    }

    func testSplitOfAMissingLineAddsNoSpeech() {
        let meetingID = MeetingID()
        let speaker = SpeakerID()
        let split = TranscriptCorrectionEvent(
            meetingID: meetingID, baseTranscriptRevision: 0, targetSegmentIDs: [UUID()],
            kind: .split([
                TranscriptCorrectionPart(text: "a", speakerID: speaker, language: nil, startTime: 0, endTime: 1),
                TranscriptCorrectionPart(text: "b", speakerID: speaker, language: nil, startTime: 1, endTime: 2),
            ]),
            sourceDeviceID: UUID(), createdAt: Date())
        let line = VoiceColumns.Line(id: UUID(), speaker: speaker, start: 5, end: 6)
        let turns = VoiceColumns.attributedTurns(lines: [line], corrections: [split])
        XCTAssertEqual(turns.map(\.start), [5])
    }
}
