import PortavozCore
import XCTest

@testable import ApplicationKit

final class MeetingPlayerStripTests: XCTestCase {
    private let meeting = Meeting(title: "Sync", startedAt: Date(timeIntervalSince1970: 0))

    func testColumnsFollowTheScrubberAxisSoAShortenedGapKeepsTheVoicesApart() throws {
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let marta = Speaker(meetingID: meeting.id, label: "S1", displayName: "Marta")
        let segments = [segment(marta.id, 0, 30), segment(me.id, 230, 260)]
        let timeline = PlaybackTimeline(duration: 260, speech: segments.map { $0.startTime...$0.endTime })
        XCTAssertFalse(timeline.gaps.isEmpty, "the 200 s pause is dead time")

        let player = strip(speakers: [me, marta], segments: segments, timeline: timeline)

        let columns = player.strip.columns
        let martaIndex = try XCTUnwrap(player.voiceIndex(of: marta.id))
        let meIndex = try XCTUnwrap(player.voiceIndex(of: me.id))
        let martaShare = Double(columns.filter { $0 == martaIndex }.count) / Double(columns.count)
        let meShare = Double(columns.filter { $0 == meIndex }.count) / Double(columns.count)
        XCTAssertGreaterThan(martaShare, 0.3, "linear binning would give each voice about 12%")
        XCTAssertEqual(martaShare, meShare, accuracy: 0.02)
        XCTAssertEqual(player.strip.tints[Int(meIndex)], .you)
        XCTAssertEqual(player.strip.tints[Int(martaIndex)], player.strip.cast.tint(for: marta.id))
        XCTAssertEqual(player.strip.duration, 260)
    }

    func testReadoutNamesWhoeverHoldsTheFloor() {
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segments = [segment(ana.id, 0, 20), segment(me.id, 5, 7), segment(ana.id, 30, 40)]
        let player = strip(
            speakers: [me, ana], segments: segments,
            timeline: PlaybackTimeline(duration: 40, speech: segments.map { $0.startTime...$0.endTime }))

        XCTAssertEqual(player.voice(at: 6)?.voice.isMe, true, "the later turn holds the floor while it lasts")
        XCTAssertEqual(player.voice(at: 10)?.voice.name, "Ana", "a turn still running outlasts a shorter one inside it")
        XCTAssertNil(player.voice(at: 25), "nobody holds a pause")
        XCTAssertEqual(player.voice(at: 30)?.label, "S1")
        XCTAssertEqual(player.myVoice?.speakerID, me.id)
        XCTAssertEqual(player.myVoice?.turns, [5...7])
    }

    func testOneVoiceAcrossDeadTimeLeavesTheGapEmpty() throws {
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let segments = [segment(me.id, 0, 30), segment(me.id, 230, 260)]
        let timeline = PlaybackTimeline(duration: 260, speech: segments.map { $0.startTime...$0.endTime })
        let gap = try XCTUnwrap(timeline.gaps.first)

        let player = strip(speakers: [me], segments: segments, timeline: timeline)

        XCTAssertNil(player.voice(at: (gap.lowerBound + gap.upperBound) / 2), "nobody holds dead time")
        XCTAssertEqual(player.voice(at: 240)?.voice.isMe, true)
        let middle = timeline.fraction(at: (gap.lowerBound + gap.upperBound) / 2)
        let columns = player.strip.columns
        XCTAssertEqual(columns[Int(middle * Double(columns.count))], VoiceColumns.silence, "the gap stays track")
    }

    func testWithoutAttributionTheLouderChannelDrawsTheStrip() throws {
        let waveform = [0.5, 0.01, 0.8, 0.9].enumerated().map { index, amplitude in
            MeetingWaveformBucket(amplitude: Float(amplitude), microphoneDominant: index == 0)
        }
        let player = strip(
            speakers: [], segments: [], timeline: PlaybackTimeline(duration: 8, speech: []), waveform: waveform)

        XCTAssertEqual(player.strip.tints, [.you, .grey])
        let columns = player.strip.columns
        XCTAssertEqual(columns.first, 0)
        XCTAssertEqual(columns[columns.count * 3 / 8], VoiceColumns.silence, "a quiet bucket stays track")
        XCTAssertEqual(columns.last, 1)
        XCTAssertTrue(player.strip.cast.voices.isEmpty, "no voice is named from volume alone")
        XCTAssertNil(player.voice(at: 1))
        XCTAssertNil(player.myVoice)
    }

    func testNoAudioAndNoTranscriptLeavesOnlyTheTrack() {
        let player = strip(speakers: [], segments: [], timeline: PlaybackTimeline(duration: 8, speech: []))
        XCTAssertTrue(player.strip.columns.isEmpty)
    }

    private func strip(
        speakers: [Speaker], segments: [TranscriptSegment], timeline: PlaybackTimeline,
        waveform: [MeetingWaveformBucket] = []
    ) -> MeetingPlayerStrip {
        MeetingPlayerStrip(
            core: MeetingReviewCore(meeting: meeting, speakers: speakers, segments: segments),
            timeline: timeline, waveform: waveform)
    }

    private func segment(_ speaker: SpeakerID?, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting.id, speakerID: speaker, channel: .system, text: "x",
            startTime: start, endTime: end, isFinal: true)
    }
}
