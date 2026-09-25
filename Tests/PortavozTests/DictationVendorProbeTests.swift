import FluidAudio
import Foundation
import XCTest

final class DictationVendorProbeTests: XCTestCase {
    // Characterization, not a desired invariant: update this when stream ownership is repaired.
    func testAttributionExposesCurrentMapperDroppingTokensAtZeroAndAtPreviousEnd() throws {
        var reduction = DictationVendorProbe.Reduction()
        let first = try reduction.apply(update([
            token("▁Do", 0, 0.2), token("▁not", 0.2, 0.4), token("▁pay", 0.4, 0.6)
        ]))
        XCTAssertEqual(first?.text, "not pay")
        let second = try reduction.apply(update([
            token("▁pay", 0.4, 0.6), token("▁today", 0.6, 0.8), token(".", 0.8, 1)
        ]))
        XCTAssertEqual(second?.text, ".")
        XCTAssertEqual(reduction.timingCount, 6)
        XCTAssertEqual(reduction.rejectedAtBoundary, 2)
        XCTAssertEqual(reduction.rejectedBeforeBoundary, 1)
        XCTAssertEqual(reduction.mappedSegmentCount, 2)
    }

    func testAttributionCountsDiscardedUpdateWithoutAdvancingItsEdge() throws {
        var reduction = DictationVendorProbe.Reduction()
        _ = try reduction.apply(update([token("▁hola", 0.1, 0.5)]))
        XCTAssertNil(try reduction.apply(update([token("▁hola", 0.1, 0.5)])))
        XCTAssertEqual(reduction.edge, 0.5)
        XCTAssertEqual(reduction.mappedSegmentCount, 1)
        XCTAssertEqual(reduction.updateCount, 2)
    }

    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 1, startTime: start, endTime: end, confidence: 1)
    }

    private func update(_ tokens: [TokenTiming]) -> SlidingWindowTranscriptionUpdate {
        SlidingWindowTranscriptionUpdate(
            text: "synthetic update", isConfirmed: false, confidence: 1, timestamp: Date(timeIntervalSince1970: 0),
            tokenIds: tokens.map(\.tokenId), tokenTimings: tokens)
    }
}
