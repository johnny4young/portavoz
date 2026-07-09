import DiarizationKit
import Foundation
import PortavozCore
import XCTest

/// Live speaker hints (spec 03): closed system rows split/labeled as the
/// live diarizer's turns arrive; the growing last row is never touched.
final class LiveSpeakerLabelerTests: XCTestCase {
    private let meetingID = MeetingID()

    private func row(
        _ text: String,
        channel: AudioChannel = .system,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            text: text,
            startTime: start,
            endTime: end,
            isFinal: true)
    }

    func testSplitsClosedRowSpanningTwoVoicesIntoTwoLabeledRows() {
        // The exact field complaint: two people back to back, coalesced
        // into ONE "Them" row — you couldn't tell they were two voices.
        let captions = [
            row("did that answer your question yes it did thanks", start: 0, end: 10),
            row("still growing…", start: 11, end: 12),
        ]
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5),
            SpeakerTurn(voiceLabel: "S2", startTime: 5, endTime: 10),
        ]

        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: turns, meetingID: meetingID)

        XCTAssertEqual(result.captions.count, 3, "closed row splits, last row rides along")
        XCTAssertEqual(result.labels[result.captions[0].id], "S1")
        XCTAssertEqual(result.labels[result.captions[1].id], "S2")
        XCTAssertFalse(result.captions[0].text.isEmpty)
        XCTAssertFalse(result.captions[1].text.isEmpty)
        // Words are dealt, never duplicated or dropped.
        let rejoined = result.captions[0].text + " " + result.captions[1].text
        XCTAssertEqual(rejoined, captions[0].text)
    }

    func testLastGrowingRowIsNeverTouched() {
        let growing = row("half a sentence", start: 0, end: 4)
        let turns = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 4)]

        let result = LiveSpeakerLabeler.relabel(
            captions: [growing], turns: turns, meetingID: meetingID)

        XCTAssertEqual(result.captions.map(\.id), [growing.id])
        XCTAssertTrue(result.labels.isEmpty)
    }

    func testRowsBeyondTurnCoverageKeepNoLabel() {
        let captions = [
            row("covered by no window yet", start: 20, end: 25),
            row("growing", start: 26, end: 27),
        ]
        let turns = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 10)]

        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: turns, meetingID: meetingID)

        XCTAssertEqual(result.captions.map(\.id), captions.map(\.id))
        XCTAssertTrue(result.labels.isEmpty)
    }

    func testIdempotentOnceSplit() {
        let captions = [
            row("one two three four five six", start: 0, end: 6),
            row("growing", start: 7, end: 8),
        ]
        let turns = [
            SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 3),
            SpeakerTurn(voiceLabel: "S2", startTime: 3, endTime: 6),
        ]

        let once = LiveSpeakerLabeler.relabel(
            captions: captions, turns: turns, meetingID: meetingID)
        let twice = LiveSpeakerLabeler.relabel(
            captions: once.captions, turns: turns, meetingID: meetingID)

        XCTAssertEqual(twice.captions.map(\.id), once.captions.map(\.id))
        XCTAssertEqual(twice.labels, once.labels)
        XCTAssertEqual(twice.captions.map(\.text), once.captions.map(\.text))
    }

    func testMicRowsAreNeverRelabeled() {
        let captions = [
            row("my own words", channel: .microphone, start: 0, end: 5),
            row("growing", start: 6, end: 7),
        ]
        let turns = [SpeakerTurn(voiceLabel: "S1", startTime: 0, endTime: 5)]

        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: turns, meetingID: meetingID)

        XCTAssertEqual(result.captions[0].id, captions[0].id)
        XCTAssertEqual(result.captions[0].text, "my own words")
        XCTAssertNil(result.labels[captions[0].id], "mic is Me by hardware, not by hint")
    }

    func testVoiceprintMeTurnLabelsSystemRowMe() {
        // Hybrid meeting: the user's voice arriving through the system
        // channel matches the enrolled voiceprint → labeled "Me" (M6).
        let captions = [
            row("that was actually me on the room mic", start: 0, end: 5),
            row("growing", start: 6, end: 7),
        ]
        let turns = [SpeakerTurn(voiceLabel: "Me", startTime: 0, endTime: 5)]

        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: turns, meetingID: meetingID)

        XCTAssertEqual(result.labels[result.captions[0].id], "Me")
    }

    func testNoTurnsIsIdentity() {
        let captions = [
            row("hello", start: 0, end: 2),
            row("growing", start: 3, end: 4),
        ]

        let result = LiveSpeakerLabeler.relabel(
            captions: captions, turns: [], meetingID: meetingID)

        XCTAssertEqual(result.captions.map(\.id), captions.map(\.id))
        XCTAssertTrue(result.labels.isEmpty)
    }
}
