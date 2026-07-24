import Foundation
import XCTest

@testable import IntegrationsKit
@testable import PortavozCore

/// Subtitle rendering with caption discipline: exact per-format timestamps,
/// bounded same-speaker merging, arrow sanitization, and the lexical bar.
final class SubtitleExportTests: XCTestCase {
    private let meeting = MeetingID()

    private func segment(
        _ text: String, start: TimeInterval, end: TimeInterval,
        speaker: SpeakerID? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting, speakerID: speaker, channel: .system,
            text: text, startTime: start, endTime: end)
    }

    func testTimestampsUseExactPerFormatSeparators() {
        // The classic subtitle bug class is unit slippage — derive from
        // milliseconds, never centiseconds.
        XCTAssertEqual(SubtitleExport.timestamp(3723.007, separator: ","), "01:02:03,007")
        XCTAssertEqual(SubtitleExport.timestamp(3723.007, separator: "."), "01:02:03.007")
        XCTAssertEqual(SubtitleExport.timestamp(0, separator: ","), "00:00:00,000")
        XCTAssertEqual(SubtitleExport.timestamp(59.9995, separator: ","), "00:01:00,000")
    }

    func testSameSpeakerMergesOnlyWithinCaptionBounds() {
        let ana = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
        let cues = SubtitleExport.cues(
            segments: [
                segment("hola equipo", start: 0, end: 2, speaker: ana.id),
                segment("revisemos el sprint", start: 2, end: 4, speaker: ana.id),
                // Beyond the duration cap measured from the cue start.
                segment("y el presupuesto", start: 8, end: 9, speaker: ana.id)
            ],
            speakers: [ana])
        XCTAssertEqual(cues.count, 2, "the six-second cap must split the cue")
        XCTAssertEqual(cues[0].text, "hola equipo revisemos el sprint")
        XCTAssertEqual(cues[0].end, 4)
        XCTAssertEqual(cues[1].text, "y el presupuesto")
    }

    func testCharacterCapDerivesFromTheConstant() {
        let ana = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
        let long = String(repeating: "a", count: SubtitleExport.maximumCueCharacters)
        let cues = SubtitleExport.cues(
            segments: [
                segment(long, start: 0, end: 1, speaker: ana.id),
                segment("cola", start: 1, end: 2, speaker: ana.id)
            ],
            speakers: [ana])
        XCTAssertEqual(cues.count, 2, "a full cue must not absorb the next row")
    }

    func testSpeakerChangeAlwaysSplitsAndPrefixesNames() {
        let ana = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let rendered = SubtitleExport.render(
            .srt,
            segments: [
                segment("primer punto", start: 0, end: 1, speaker: ana.id),
                segment("de acuerdo", start: 1, end: 2, speaker: me.id)
            ],
            speakers: [ana, me])
        XCTAssertTrue(rendered.contains("Ana: primer punto"))
        XCTAssertTrue(rendered.contains("Me: de acuerdo"))
        XCTAssertTrue(rendered.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\n"))
    }

    func testArrowInsideSpeechCannotForgeACueBoundary() {
        let cues = SubtitleExport.cues(
            segments: [segment("A --> B es la ruta", start: 0, end: 2)],
            speakers: [])
        XCTAssertEqual(cues[0].displayText, "A -> B es la ruta")
    }

    func testNonLexicalRowsStayOut() {
        let cues = SubtitleExport.cues(
            segments: [
                segment(".", start: 0, end: 1),
                segment("contenido real", start: 1, end: 2)
            ],
            speakers: [])
        XCTAssertEqual(cues.map(\.text), ["contenido real"])
    }

    func testVTTCarriesHeaderAndPeriodSeparators() {
        let rendered = SubtitleExport.render(
            .vtt,
            segments: [segment("hola", start: 0, end: 1.5)],
            speakers: [])
        XCTAssertTrue(rendered.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(rendered.contains("00:00:00.000 --> 00:00:01.500"))
        XCTAssertFalse(rendered.contains(","), "VTT rejects comma separators")
    }
}
