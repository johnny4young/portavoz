import Foundation
import PortavozCore
import XCTest

@testable import DiarizationKit
@testable import portavoz_app

/// Live relabeling ran `slice` over every turn for every segment, so each new
/// turn cost O(segments x turns) on the main actor. The bounded window must
/// produce byte-identical attribution, and a pass that changes nothing must
/// not republish the caption array.
final class SpeakerAttributionWindowTests: XCTestCase {
    private let meetingID = MeetingID(rawValue: UUID(
        uuidString: "A11C0000-0000-4000-8000-000000000001")!)

    func testWindowedAttributionMatchesAFullScanOverManyTurns() {
        let segments = (0..<60).map { index in
            segment(start: Double(index) * 5, end: Double(index) * 5 + 5)
        }
        // Turns deliberately overlap and are supplied out of order, so the
        // window cannot rely on the diarizer's arrival order.
        var turns: [SpeakerTurn] = []
        for index in 0..<120 {
            let start = Double(index) * 2.5
            turns.append(SpeakerTurn(
                voiceLabel: index.isMultiple(of: 2) ? "S1" : "S2",
                startTime: start,
                endTime: start + 3.1))
        }
        turns.shuffle()

        let attribution = SpeakerAttributor.attribute(
            segments: segments, turns: turns, meetingID: meetingID)
        let reference = referenceAttribution(segments: segments, turns: turns)

        XCTAssertEqual(attribution.segments.count, reference.count)
        for (produced, expected) in zip(attribution.segments, reference) {
            XCTAssertEqual(produced.text, expected.text)
            XCTAssertEqual(produced.startTime, expected.startTime, accuracy: 1e-9)
            XCTAssertEqual(produced.endTime, expected.endTime, accuracy: 1e-9)
        }
    }

    /// The window starts from the first turn that can still be open, not the
    /// first that starts late enough: one long early turn spanning the whole
    /// meeting must reach a segment near the end.
    func testALongEarlyTurnStillCoversLaterSegments() {
        let segments = (0..<20).map { index in
            segment(start: Double(index) * 5, end: Double(index) * 5 + 5)
        }
        var turns = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 100)]
        for index in 0..<20 {
            turns.append(SpeakerTurn(
                voiceLabel: "S2",
                startTime: Double(index) * 5 + 1,
                endTime: Double(index) * 5 + 2))
        }
        turns.shuffle()

        let attribution = SpeakerAttributor.attribute(
            segments: segments, turns: turns, meetingID: meetingID)
        let reference = referenceAttribution(segments: segments, turns: turns)

        XCTAssertEqual(attribution.segments.count, reference.count)
        for (produced, expected) in zip(attribution.segments, reference) {
            XCTAssertEqual(produced.text, expected.text)
            XCTAssertEqual(produced.startTime, expected.startTime, accuracy: 1e-9)
            XCTAssertEqual(produced.endTime, expected.endTime, accuracy: 1e-9)
        }
    }

    func testAnEmptyOrSingleTurnStillAttributesTheWholeSegment() {
        let only = [segment(start: 0, end: 4)]
        XCTAssertEqual(
            SpeakerAttributor.attribute(
                segments: only, turns: [], meetingID: meetingID).segments.count,
            1)
        let covered = SpeakerAttributor.attribute(
            segments: only,
            turns: [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 4)],
            meetingID: meetingID)
        XCTAssertEqual(covered.segments.count, 1)
        XCTAssertNotNil(covered.segments[0].speakerID)
    }

    func testIdenticalRelabelIsNotRepublished() {
        let rows = [segment(start: 0, end: 4), segment(start: 4, end: 8)]
        let labels: [UUID: String] = [rows[0].id: "S1"]

        XCTAssertFalse(
            LiveSpeakerHints.changed(from: (rows, labels), to: (rows, labels)),
            "an unchanged pass must not re-project the transcript")

        // `SpeakerAttributor` mints a fresh SpeakerID on every pass, so the id
        // changing means nothing happened. Comparing it made this guard report
        // a change on every diarizer turn and suppress nothing at all.
        var reminted = rows
        reminted[1].speakerID = SpeakerID()
        XCTAssertFalse(
            LiveSpeakerHints.changed(from: (rows, labels), to: (reminted, labels)),
            "a re-minted speaker id is not a change the reader can see")

        let moved = [rows[0], segment(start: 4, end: 9)]
        XCTAssertTrue(
            LiveSpeakerHints.changed(from: (rows, labels), to: (moved, labels)),
            "a row whose bounds moved is a change the reader can see")
        XCTAssertTrue(
            LiveSpeakerHints.changed(from: (rows, labels), to: (rows, [:])))
        XCTAssertTrue(
            LiveSpeakerHints.changed(
                from: (rows, labels),
                to: (Array(rows.dropLast()), labels)))
    }

    /// The pre-window behaviour: every turn considered for every segment.
    private func referenceAttribution(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        var expected: [TranscriptSegment] = []
        for source in segments {
            let pieces = SpeakerAttributor.slice(source, across: turns)
            guard pieces.count > 1 else {
                expected.append(source)
                continue
            }
            for piece in pieces where !piece.text.isEmpty {
                expected.append(TranscriptSegment(
                    meetingID: source.meetingID,
                    speakerID: nil,
                    channel: source.channel,
                    text: piece.text,
                    startTime: piece.startTime,
                    endTime: piece.endTime,
                    isFinal: source.isFinal))
            }
        }
        return expected
    }

    private func segment(start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            speakerID: nil,
            channel: .system,
            text: "uno dos tres cuatro cinco seis",
            startTime: start,
            endTime: end,
            isFinal: true)
    }
}
