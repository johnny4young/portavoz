import PortavozCore
import XCTest

final class StreamingLinearResamplerTests: XCTestCase {
    func testInvalidRatesAndNegativeCapsAreRejected() {
        for (source, target, cap) in [
            (0.0, 16_000.0, 10), (-1.0, 16_000.0, 10), (.nan, 16_000.0, 10),
            (48_000.0, .infinity, 10), (48_000.0, 16_000.0, -1),
        ] {
            var resampler = StreamingLinearResampler()
            XCTAssertThrowsError(try resampler.resample(
                [0, 1], from: source, to: target, maximumOutputSamples: cap))
        }
    }

    func testOutputCapBindsBothTheEqualRateAndInterpolatingPaths() throws {
        var equal = StreamingLinearResampler()
        XCTAssertThrowsError(try equal.resample(
            [Float](repeating: 0, count: 5), from: 16_000, to: 16_000, maximumOutputSamples: 4))
        XCTAssertEqual(try equal.resample(
            [Float](repeating: 0, count: 4), from: 16_000, to: 16_000, maximumOutputSamples: 4).count, 4)

        var upsampling = StreamingLinearResampler()
        XCTAssertThrowsError(try upsampling.resample(
            [Float](repeating: 0, count: 100), from: 8_000, to: 16_000, maximumOutputSamples: 150))
        XCTAssertEqual(try upsampling.resample(
            [Float](repeating: 0, count: 100), from: 8_000, to: 16_000, maximumOutputSamples: 199).count, 199)
    }

    func testRateChangeDropsCarriedPhaseAndSample() throws {
        var resampler = StreamingLinearResampler()
        _ = try resampler.resample([1, 1, 1], from: 48_000, to: 16_000, maximumOutputSamples: 10)
        let changed = try resampler.resample([0, 0, 0, 0], from: 32_000, to: 16_000, maximumOutputSamples: 10)
        XCTAssertEqual(changed, [0, 0], "a new rate must not interpolate from the previous stream")
    }
}
