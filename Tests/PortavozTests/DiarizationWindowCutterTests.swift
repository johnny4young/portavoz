import Foundation
import XCTest

@testable import DiarizationKit

/// The live turn timeline must be the session's, not the consumer's. Live
/// diarization attaches after capture begins and reads a bounded stream that
/// drops audio under back-pressure, so anything derived from "how much this
/// task received" places turns earlier than they happened.
final class DiarizationWindowCutterTests: XCTestCase {
    private let rate = 1_000
    private let windowSeconds: TimeInterval = 2

    private func cutter() -> DiarizationWindowCutter {
        DiarizationWindowCutter(
            windowSeconds: windowSeconds,
            sampleRate: rate,
            minimumSeconds: 0.5,
            tolerance: 0.25)
    }

    private func chunk(_ seconds: TimeInterval) -> [Float] {
        [Float](repeating: 0.5, count: Int(seconds * TimeInterval(rate)))
    }

    func testWindowsAreAnchoredToTheSessionClockNotTheConsumer() {
        var cutter = cutter()

        // The consumer attached 30 s into the meeting: the first window it
        // completes is at 30 s, not at 0.
        XCTAssertTrue(cutter.accept(chunk(1), at: 30).isEmpty)
        let first = cutter.accept(chunk(1), at: 31)
        let second = cutter.accept(chunk(2), at: 32)

        XCTAssertEqual(first.map(\.start), [30])
        XCTAssertEqual(second.map(\.start), [32])
        XCTAssertEqual(first.first?.samples.count, Int(windowSeconds) * rate)
    }

    func testDroppedAudioShiftsNothingThatFollowsIt() {
        var cutter = cutter()
        _ = cutter.accept(chunk(1), at: 0)

        // The stream dropped 5 s. The next window must sit where the audio
        // actually is, and must not splice across the gap.
        let released = cutter.accept(chunk(2), at: 6)

        XCTAssertEqual(
            released.map(\.start),
            [0, 6],
            "the held second is released on its own, then the new window lands at 6")
        XCTAssertEqual(released.first?.samples.count, rate, "one second, unspliced")
        XCTAssertEqual(
            released.last?.samples.count,
            Int(windowSeconds) * rate)
    }

    func testAGapShorterThanTheToleranceIsTreatedAsContiguous() {
        var cutter = cutter()
        _ = cutter.accept(chunk(1), at: 0)

        // 0.1 s of resampling rounding, well inside the tolerance.
        let released = cutter.accept(chunk(1), at: 1.1)

        XCTAssertEqual(released.map(\.start), [0])
        XCTAssertEqual(
            released.first?.samples.count,
            Int(windowSeconds) * rate,
            "both chunks belong to one window")
    }

    func testATailShorterThanTheMinimumCarriesNoTurn() {
        var cutter = cutter()
        _ = cutter.accept(chunk(0.2), at: 10)

        XCTAssertNil(cutter.flush())

        _ = cutter.accept(chunk(0.8), at: 20)
        let tail = cutter.flush()
        XCTAssertEqual(tail?.start, 20)
        XCTAssertNil(cutter.flush(), "a flushed tail is not emitted twice")
    }

    func testANonFiniteTimestampNeverAnchorsAWindow() {
        var cutter = cutter()
        _ = cutter.accept(chunk(1), at: 5)

        let released = cutter.accept(chunk(1), at: .nan)

        XCTAssertEqual(
            released.map(\.start),
            [5],
            "the held audio is released; the unusable chunk is not appended")
        XCTAssertNil(cutter.flush())
    }
}
