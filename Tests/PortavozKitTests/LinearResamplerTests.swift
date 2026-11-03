import Foundation
import XCTest

@testable import AudioCaptureKit

/// Flooring each callback's output count independently drops the remainder
/// every time, so a rate-mismatched device slowly falls behind the host clock
/// until the delivery accounting injects a half-second silence pad.
final class LinearResamplerTests: XCTestCase {
    func testStreamedBuffersStayAlignedWithTheHostClock() throws {
        var resampler = LinearResampler()
        let callbackFrames = 4096
        let callbacks = 200
        let buffer = [Float](repeating: 0.25, count: callbackFrames)

        var produced = 0
        for _ in 0..<callbacks {
            produced += try resampler.resample(buffer, from: 44_100, to: 48_000).count
        }

        let exact = Double(callbackFrames * callbacks) * 48_000 / 44_100
        XCTAssertLessThanOrEqual(
            abs(Double(produced) - exact), 1,
            "the carried phase must keep the stream within one frame of exact")

    }

    func testSameRateAndEmptyInputStayPassthrough() throws {
        var resampler = LinearResampler()
        let samples: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(
            try resampler.resample(samples, from: 48_000, to: 48_000), samples)
        XCTAssertTrue(try resampler.resample([], from: 44_100, to: 48_000).isEmpty)
    }

    func testInterpolationSpansTheBufferBoundary() throws {
        var resampler = LinearResampler()
        // 24 kHz to 48 kHz doubles: the sample between the buffers must be the
        // midpoint of the last sample of one and the first of the next, which
        // is only reachable if the previous buffer's tail is carried.
        _ = try resampler.resample([0, 1], from: 24_000, to: 48_000)
        let second = try resampler.resample([0, 1], from: 24_000, to: 48_000)
        XCTAssertEqual(second.first ?? -1, 0.5, accuracy: 0.0001,
                       "the boundary sample interpolates across the seam")
    }

    func testInvalidRatesFailBeforeAllocating() {
        var resampler = LinearResampler()
        for rate in [Double.nan, .infinity, 0, -1] {
            XCTAssertThrowsError(
                try resampler.resample([0, 1], from: rate, to: 48_000))
            XCTAssertThrowsError(
                try resampler.resample([0, 1], from: 48_000, to: rate))
        }
    }

    func testResetReturnsToAFreshStream() throws {
        var resampler = LinearResampler()
        let first = try resampler.resample([0, 1, 0, 1], from: 44_100, to: 48_000)
        resampler.reset()
        let afterReset = try resampler.resample([0, 1, 0, 1], from: 44_100, to: 48_000)
        XCTAssertEqual(first, afterReset)
    }

    func testEmptyOrInvalidBuffersDoNotRetireAnActiveConversion() throws {
        var resampler = LinearResampler()
        _ = try resampler.resample([0, 1], from: 24_000, to: 48_000)
        XCTAssertTrue(try resampler.resample([], from: 48_000, to: 48_000).isEmpty)
        XCTAssertThrowsError(try resampler.resample([9], from: .nan, to: 48_000))
        XCTAssertEqual(try resampler.resample([2, 3], from: 24_000, to: 48_000), [1.5, 2, 2.5, 3])
    }

    func testTargetRateChangeAlsoRetiresTheOldPhase() throws {
        var resampler = LinearResampler()
        _ = try resampler.resample([0, 1], from: 24_000, to: 48_000)
        XCTAssertEqual(try resampler.resample([10, 11], from: 24_000, to: 96_000),
                       [10, 10.25, 10.5, 10.75, 11])
    }

    func testUnevenFragmentMatrixPreservesTheSignalAndBoundsInterpolationTail() throws {
        let rates: [Double] = [8_000, 16_000, 24_000, 44_100, 48_000, 96_000]
        for source in rates {
            for target in rates {
                var resampler = LinearResampler()
                var inputCount = 0
                var output: [Float] = []
                for count in Array(repeating: [1, 2, 3, 17, 64], count: 20).flatMap({ $0 }) {
                    let input = (inputCount..<(inputCount + count)).map(Float.init)
                    let actual = try resampler.resample(input, from: source, to: target)
                    let reserved = try CapturePCMGeometry.resampling(
                        inputCount: count, source: source, target: target).frameCount
                        + CaptureDeliveryBuffer.streamingCarryFrames
                    XCTAssertLessThanOrEqual(actual.count, reserved)
                    output += actual
                    inputCount += count
                }
                // A linear ramp has an independent interpolation oracle. Only
                // the not-yet-arrived next source sample may delay the tail.
                for (index, actual) in output.enumerated() {
                    XCTAssertEqual(actual, Float(Double(index) * source / target), accuracy: 0.001)
                }
                let exact = Double(inputCount) * target / source
                XCTAssertLessThanOrEqual(abs(Double(output.count) - exact), max(1, target / source))
                var constant = LinearResampler()
                let constantOutput = try constant.resample(
                    Array(repeating: Float(0.7), count: 17), from: source, to: target)
                XCTAssertFalse(constantOutput.isEmpty)
                for value in constantOutput { XCTAssertEqual(value, 0.7, accuracy: 0.0001) }
            }
        }
    }
}

/// The streaming resampler carries a fractional frame between callbacks, so it
/// can emit one more frame than the single-shot geometry reserves. The delivery
/// gate has to reserve that frame, or a packet is admitted and then rejected on
/// append — which terminates the capture as `.overloaded` mid-meeting.
final class StreamingCarryAdmissionTests: XCTestCase {
    func testTheGateReservesEveryFrameTheStreamCanEmit() throws {
        for (source, target) in [
            (44_100.0, 48_000.0), (48_000.0, 44_100.0), (16_000.0, 48_000.0)
        ] {
            var resampler = LinearResampler()
            for _ in 0..<200 {
                let input = [Float](repeating: 0, count: 4096)
                let reserved = try CapturePCMGeometry.resampling(
                    inputCount: input.count, source: source, target: target)
                    .frameCount + CaptureDeliveryBuffer.streamingCarryFrames
                let produced = try resampler.resample(
                    input, from: source, to: target).count
                XCTAssertLessThanOrEqual(
                    produced, reserved,
                    "\(Int(source))->\(Int(target)) emitted more than the gate admitted")
            }
        }
    }
}
