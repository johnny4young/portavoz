import Foundation
import XCTest

@testable import IntegrationsKit

final class PlaybackRangesTests: XCTestCase {
    func testComplementIsTheGapsAroundVoiceRanges() {
        // Voice at 10–20 and 40–50 within a 60 s meeting (no padding).
        let gaps = PlaybackRanges.complement(
            of: [10...20, 40...50], within: 60)
        // Gaps: [0,~10], [~20,~40], [~50,60] — with a 0.25 s pad on voice.
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0].lowerBound, 0)
        XCTAssertEqual(gaps[0].upperBound, 9.75, accuracy: 0.01)
        XCTAssertEqual(gaps[1].lowerBound, 20.25, accuracy: 0.01)
        XCTAssertEqual(gaps[2].upperBound, 60)
    }

    func testMergeCollapsesOverlappingRanges() {
        let merged = PlaybackRanges.merge([0...5, 4...9, 20...22], margin: 0)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], 0...9)
        XCTAssertEqual(merged[1], 20...22)
    }

    func testNoVoiceMeansTheWholeMeetingIsSkippable() {
        XCTAssertEqual(PlaybackRanges.complement(of: [], within: 30), [0...30])
    }

    func testVoiceCoveringEverythingLeavesNoGaps() {
        XCTAssertTrue(PlaybackRanges.complement(of: [0...30], within: 30).isEmpty)
    }

    func testZeroDuration() {
        XCTAssertTrue(PlaybackRanges.complement(of: [1...2], within: 0).isEmpty)
    }
}
