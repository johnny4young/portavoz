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
        XCTAssertEqual(stage.voiceCount, 2)
    }

    func testTheHeroStepsItsTypeDownWithWidth() {
        XCTAssertEqual(RecordingStageHeroScale(width: 1_200), .wide)
        XCTAssertEqual(RecordingStageHeroScale(width: 840), .wide)
        XCTAssertEqual(RecordingStageHeroScale(width: 839), .medium)
        XCTAssertEqual(RecordingStageHeroScale(width: 679), .compact)
        XCTAssertGreaterThan(RecordingStageHeroScale.wide.clock, RecordingStageHeroScale.medium.clock)
        XCTAssertGreaterThan(RecordingStageHeroScale.medium.clock, RecordingStageHeroScale.compact.clock)
    }

    func testTheSpeakerLineNamesWhoSpeaksThenTheTwoBefore() throws {
        let meetingID = MeetingID()
        func row(_ channel: AudioChannel, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
            TranscriptSegment(
                meetingID: meetingID, channel: channel, text: "words",
                startTime: start, endTime: end, isFinal: true)
        }
        let s1 = row(.system, 0, 10)
        let s2 = row(.system, 10, 20)
        let s3 = row(.system, 20, 30)
        let mine = row(.microphone, 30, 40)
        let labels = [s1.id: "S1", s2.id: "S2", s3.id: "S3"]
        let speaking = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: [s1, s2, s3, mine], labels: labels, latestTurn: nil, now: 40))
        let line = try XCTUnwrap(LiveSpeakerLine(stage: speaking, cast: speaking.cast()))

        XCTAssertEqual(line.name, "You")
        XCTAssertEqual(line.speakingDetail, "speaking · then S3, S2")
        XCTAssertEqual(line.spoken, "You speaking, then S3, S2")
        XCTAssertEqual(line.voices, "4 voices")
        XCTAssertEqual(String(line.styled.characters), "You speaking · then S3, S2")

        let quiet = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: [s1, s2, s3, mine], labels: labels, latestTurn: nil, now: 60))
        let after = try XCTUnwrap(LiveSpeakerLine(stage: quiet, cast: quiet.cast()))
        XCTAssertFalse(after.lead.isSpeaking)
        XCTAssertEqual(after.spoken, "Last heard: You, S3, S2")

        let alone = LiveVoiceStage.updating(.empty, with: LiveVoiceSource(
            captions: [mine], labels: [:], latestTurn: nil, now: 40))
        let solo = try XCTUnwrap(LiveSpeakerLine(stage: alone, cast: alone.cast()))
        XCTAssertEqual(solo.speakingDetail, "speaking")
        XCTAssertEqual(solo.voices, "1 voice")
        XCTAssertNil(LiveSpeakerLine(stage: .empty, cast: LiveVoiceStage.empty.cast()))
    }

    func testRecentRowsReadTheClockTodayAndTheDayBefore() {
        let now = Date()
        let locale = AppLanguage.current.locale
        XCTAssertEqual(MenuBarFormat.started(now), now.formatted(.dateTime.hour().minute().locale(locale)))
        let earlier = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(
            MenuBarFormat.started(earlier), earlier.formatted(.dateTime.month(.abbreviated).day().locale(locale)))
        let event = UpcomingEvent(id: "e", title: "Sync", startDate: now, attendees: ["Ana", "Bo", "Cy", "Di"])
        XCTAssertTrue(MenuBarFormat.eventDetail(event).hasSuffix(" · Ana, Bo, Cy +1"))
    }
}
