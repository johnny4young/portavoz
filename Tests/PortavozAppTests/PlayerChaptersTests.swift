import ApplicationKit
import Testing

@testable import portavoz_app

struct PlayerChaptersTests {
    @Test func chaptersPastTheAudioHaveNoTickAndPlaybackFindsItsChapter() {
        let timeline = PlaybackTimeline(duration: 100, speech: [0...100])
        let chapters = PlayerChapters(
            [chapter(0, "Opening"), chapter(50, "Rollout"), chapter(200, "After the audio")], timeline: timeline)

        #expect(chapters.titles == ["Opening", "Rollout"])
        #expect(chapters.ticks == [0, 0.5])
        #expect(chapters.index(at: 49.9) == 0)
        #expect(chapters.index(at: 49.96) == 1, "a seek a frame short of a chapter counts as in it")
        #expect(chapters.index(at: 99) == 1)
    }

    @Test func aShortenedGapMovesTheTickWithTheStrip() {
        let timeline = PlaybackTimeline(duration: 300, speech: [0...30, 270...300])
        let chapters = PlayerChapters([chapter(270, "Second half")], timeline: timeline)

        // 31 s of speech, the silence drawn as 10 s, then 1 s into the last part: 42 of 72.
        #expect(abs((chapters.ticks.first ?? 0) - 42.0 / 72.0) < 0.001, "linear would put it at 0.9")
        #expect(PlayerChapters([], timeline: timeline).index(at: 10) == nil)
    }

    private func chapter(_ start: Double, _ title: String) -> MeetingTranscriptContent.Chapter {
        MeetingTranscriptContent.Chapter(startTime: start, title: title)
    }
}
