import ApplicationKit
import XCTest

final class PlaybackTimelineTests: XCTestCase {
    /// Field shape: a six-minute call, then 2 h 43 min until Stop.
    private let forgottenStop = PlaybackTimeline(
        duration: 10_152,
        speech: [0...120, 125...380])

    func testDeadTimeAfterTheCallIsOneShortGap() throws {
        XCTAssertEqual(forgottenStop.gaps, [381...10_152])
        let gap = try XCTUnwrap(forgottenStop.parts.last)
        XCTAssertTrue(gap.isGap)
        XCTAssertEqual(gap.displayLength, 38.1, accuracy: 0.01, "a tenth of the conversation")
        XCTAssertGreaterThan(forgottenStop.fraction(at: 380), 0.9, "the call fills the scrubber")
    }

    func testTimeAndFractionRoundTrip() {
        for time in [0, 60, 200, 380, 400, 5_000, 10_152] as [TimeInterval] {
            XCTAssertEqual(
                forgottenStop.time(at: forgottenStop.fraction(at: time)), time, accuracy: 0.001)
        }
        XCTAssertEqual(forgottenStop.fraction(at: 0), 0)
        XCTAssertEqual(forgottenStop.fraction(at: 10_152), 1)
    }

    func testConversationalPausesStayAtTrueLength() {
        let timeline = PlaybackTimeline(duration: 120, speech: [0...50, 60...120])

        XCTAssertTrue(timeline.gaps.isEmpty)
        XCTAssertEqual(timeline.fraction(at: 60), 0.5, accuracy: 1e-9)
    }

    func testLeadingSilenceIsCompressedToo() {
        let timeline = PlaybackTimeline(duration: 600, speech: [300...600])

        XCTAssertEqual(timeline.gaps, [0...299])
    }

    func testWithoutTranscriptTheScrubberIsLinear() {
        let timeline = PlaybackTimeline(duration: 100, speech: [])

        XCTAssertTrue(timeline.gaps.isEmpty)
        XCTAssertEqual(timeline.fraction(at: 25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(timeline.time(at: 0.75), 75, accuracy: 1e-9)
    }

    func testSpeechPastTheEndOfAShorterFileIsClamped() {
        let timeline = PlaybackTimeline(duration: 5, speech: [0...3, 3...6, 6...8, 200...205])

        XCTAssertTrue(timeline.gaps.isEmpty)
        XCTAssertEqual(timeline.fraction(at: 5), 1)

        let longer = PlaybackTimeline(duration: 100, speech: [0...8, 200...205])
        XCTAssertEqual(longer.gaps, [9...100])
    }

    func testFractionsOutsideTheScrubberAreClamped() {
        XCTAssertEqual(forgottenStop.time(at: -1), 0)
        XCTAssertEqual(forgottenStop.time(at: 2), 10_152, accuracy: 1e-6)
        XCTAssertEqual(PlaybackTimeline(duration: 0, speech: []).fraction(at: 5), 0)
    }
}
