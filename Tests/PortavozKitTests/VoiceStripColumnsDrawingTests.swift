import ApplicationKit
import PortavozCore
import XCTest

final class VoiceStripColumnsDrawingTests: XCTestCase {
    private let silence = VoiceColumns.silence

    private func run(_ voice: UInt8, _ start: Int, _ end: Int) -> VoiceColumns.Run {
        VoiceColumns.Run(voice: voice, start: start, end: end)
    }

    func testEmptyOrInvalidCountsDrawNothing() {
        XCTAssertEqual(VoiceColumns.resampled([], count: 4), [])
        XCTAssertEqual(VoiceColumns.resampled([0, 1], count: 0), [])
        XCTAssertEqual(VoiceColumns.resampled([0, 1], count: -3), [])
        XCTAssertEqual(VoiceColumns.runs([]), [])
    }

    func testAStripAtOrUnderTheCountIsUnchanged() {
        let columns: [UInt8] = [0, silence, 1]
        XCTAssertEqual(VoiceColumns.resampled(columns, count: 3), columns)
        XCTAssertEqual(VoiceColumns.resampled(columns, count: 10), columns)
    }

    func testEachTargetTakesTheVoiceHoldingMostOfItsSpan() {
        let columns: [UInt8] = [0, 0, 1, 2, 2, 2, 1, silence]
        XCTAssertEqual(VoiceColumns.resampled(columns, count: 2), [0, 2])
    }

    func testAVoiceUnderThirtyPercentOfTheSpanIsSilence() {
        let quarter: [UInt8] = [3, silence, silence, silence]
        XCTAssertEqual(VoiceColumns.resampled(quarter, count: 1), [silence])
        let half: [UInt8] = [silence, 3, 3, silence]
        XCTAssertEqual(VoiceColumns.resampled(half, count: 1), [3])
        // Exactly 30% still counts.
        let tenth: [UInt8] = [4, 4, 4] + Array(repeating: silence, count: 7)
        XCTAssertEqual(VoiceColumns.resampled(tenth, count: 1), [4])
    }

    func testTiesGoToTheLowerVoice() {
        XCTAssertEqual(VoiceColumns.resampled([2, 1, 1, 2], count: 1), [1])
        XCTAssertEqual(VoiceColumns.resampled([1, 0, 0, 1], count: 2), [0, 0])
    }

    func testFractionalSpansWeighPartialColumns() {
        // Each target spans 1.5 columns: the middle column is shared half and half.
        XCTAssertEqual(VoiceColumns.resampled([0, 1, 1], count: 2), [0, 1])
        XCTAssertEqual(VoiceColumns.resampled([0, 0, 1], count: 2), [0, 1])
    }

    func testAllSilenceStaysSilence() {
        XCTAssertEqual(
            VoiceColumns.resampled(Array(repeating: silence, count: 6), count: 3),
            [silence, silence, silence])
    }

    func testAStoredStripFoldsToAnySmallerCount() {
        let stored = (0..<VoiceColumns.storedCount).map { UInt8($0 < 100 ? 0 : 1) }
        for count in [1, 7, 60, 199] {
            let folded = VoiceColumns.resampled(stored, count: count)
            XCTAssertEqual(folded.count, count)
            XCTAssertEqual(folded.first, 0)
            XCTAssertEqual(folded.last, count == 1 ? 0 : 1)
        }
    }

    func testRunsSkipSilenceAndEndExclusive() {
        let columns: [UInt8] = [0, 0, silence, 1, 1, 1, 0]
        XCTAssertEqual(VoiceColumns.runs(columns), [run(0, 0, 2), run(1, 3, 6), run(0, 6, 7)])
        XCTAssertEqual(VoiceColumns.runs([silence, silence]), [])
        XCTAssertEqual(VoiceColumns.runs([5]), [run(5, 0, 1)])
    }
}
