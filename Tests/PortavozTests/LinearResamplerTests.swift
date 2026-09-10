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
        var singleShot = 0
        for _ in 0..<callbacks {
            produced += try resampler.resample(buffer, from: 44_100, to: 48_000).count
            singleShot += try Resample.linear(buffer, from: 44_100, to: 48_000).count
        }

        let exact = Double(callbackFrames * callbacks) * 48_000 / 44_100
        XCTAssertLessThanOrEqual(
            abs(Double(produced) - exact), 1,
            "the carried phase must keep the stream within one frame of exact")
        // The single-shot form is what the sources used to call per callback.
        // At 4096 frames it floors 4458.23 to 4458, losing ~0.23 frames each
        // time — about 46 frames over these 200 callbacks, and unbounded over
        // a meeting.
        XCTAssertGreaterThan(
            exact - Double(singleShot), 20,
            "the per-buffer floor really did lose frames at this rate")
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
