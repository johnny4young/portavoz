import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class RecordingStageFormatTests: XCTestCase {
    func testRecencyReadsSecondsThenMinutesThenHours() {
        XCTAssertEqual(LiveVoiceRecencyFormat.ago(0.4), "1 s ago", "never “0 s ago”")
        XCTAssertEqual(LiveVoiceRecencyFormat.ago(12.9), "12 s ago")
        XCTAssertEqual(LiveVoiceRecencyFormat.ago(60), "1 min ago")
        XCTAssertEqual(LiveVoiceRecencyFormat.ago(3_599), "59 min ago")
        XCTAssertEqual(LiveVoiceRecencyFormat.ago(7_300), "2 h ago")
    }

    func testTheCurrentSpeakerReadsHowLongTheyHaveSpoken() throws {
        let meetingID = MeetingID()
        let mine = TranscriptSegment(
            meetingID: meetingID, channel: .microphone, text: "words",
            startTime: 10, endTime: 30, isFinal: true)
        let stage = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: [mine], labels: [:], latestTurn: nil, now: 30))
        let you = try XCTUnwrap(LiveVoiceTable(stage: stage, cast: stage.cast()).rows.first)

        XCTAssertEqual(LiveVoiceRecencyFormat.text(row: you, now: 30), "speaking now · 0:20")
        XCTAssertEqual(
            LiveVoiceRecencyFormat.text(row: you, now: 90), "speaking now",
            "an open microphone with no new row yet has no turn to time")
    }

    func testTheDetailLineNamesTheAppTheStartAndTheVoices() {
        let start = Date(timeIntervalSince1970: 0)
        let started = start.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale))

        XCTAssertEqual(
            RecordingStageDetail.line(apps: ["Meet"], startedAt: start, voices: 12),
            "Meet · started \(started) · 12 voices so far")
        XCTAssertEqual(
            RecordingStageDetail.line(apps: [], startedAt: start, voices: 1),
            "started \(started) · 1 voice so far")
        XCTAssertEqual(RecordingStageDetail.line(apps: [], startedAt: start, voices: 0), "started \(started)")
    }

    func testUnlabelledRemoteSpeechIsNotCountedAsAVoice() {
        let meetingID = MeetingID()
        func row(_ channel: AudioChannel, _ start: TimeInterval) -> TranscriptSegment {
            TranscriptSegment(
                meetingID: meetingID, channel: channel, text: "words",
                startTime: start, endTime: start + 2, isFinal: true)
        }
        let labelled = row(.system, 3)
        let stage = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: [row(.microphone, 0), labelled, row(.system, 6)],
            labels: [labelled.id: "S1"], latestTurn: nil, now: 8))

        XCTAssertEqual(stage.voices.map(\.key), ["you", "S1", "remote"])
        XCTAssertEqual(RecordingStageDetail.voiceCount(stage), 2)
    }

    func testTheHeroStepsItsTypeDownWithWidth() {
        XCTAssertEqual(RecordingStageHeroScale(width: 1_200), .wide)
        XCTAssertEqual(RecordingStageHeroScale(width: 840), .wide)
        XCTAssertEqual(RecordingStageHeroScale(width: 839), .medium)
        XCTAssertEqual(RecordingStageHeroScale(width: 679), .compact)
        XCTAssertGreaterThan(RecordingStageHeroScale.wide.clock, RecordingStageHeroScale.medium.clock)
        XCTAssertGreaterThan(RecordingStageHeroScale.medium.clock, RecordingStageHeroScale.compact.clock)
    }
}
