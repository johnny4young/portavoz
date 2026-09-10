import AVFAudio
import Foundation
import XCTest
@testable import AudioCaptureKit

final class CapturePCMGeometryTests: XCTestCase {
    private let rates: [Double] = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000, 96_000, 192_000, 384_000]

    func testNormalRateMatrixBoundsAllocationAdmission() throws {
        for source in rates {
            for target in rates {
                for inputCount in [0, 1, 2, 441, 4096] {
                    let plan = try CapturePCMGeometry.resampling(inputCount: inputCount, source: source, target: target)
                    let expected = inputCount == 0 ? 0 : max(1, Int((Double(inputCount) / (source / target)).rounded(.down)))
                    XCTAssertEqual(plan.frameCount, expected)
                }
            }
        }
    }

    func testInvalidRatesFailEvenForEmptyOrSameRateInputRatherThanPassingThrough() {
        for rate in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertFalse(CapturePCMGeometry.isUsable(sampleRate: rate))
            for samples: [Float] in [[], [0, 1]] {
                var resampler = LinearResampler()
                XCTAssertThrowsError(try resampler.resample(samples, from: rate, to: 48_000))
                XCTAssertThrowsError(try resampler.resample(samples, from: 48_000, to: rate))
                XCTAssertThrowsError(try resampler.resample(samples, from: rate, to: rate))
            }
        }
    }

    func testNonfiniteUnderflowAndNativeCapacityRatiosRejectBeforeAllocating() {
        for (source, target) in [
            (Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude),
            (Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude),
            (1, Double.greatestFiniteMagnitude),
            (0.000_000_000_1, 1)
        ] {
            XCTAssertThrowsError(try CapturePCMGeometry.resampling(inputCount: 4, source: source, target: target))
        }
        for count in [-1, Int.min, Int(UInt32.max) + 1, Int.max] {
            XCTAssertThrowsError(try CapturePCMGeometry.resampling(inputCount: count, source: 48_000, target: 48_000))
        }
    }

    func testNativeCapacityAdmissionIsExactWithoutAllocatingItsBoundary() throws {
        XCTAssertEqual(try CapturePCMGeometry.nativeFrameCount(0), 0)
        XCTAssertEqual(try CapturePCMGeometry.nativeFrameCount(Int(UInt32.max)), UInt32.max)
        for count in [-1, Int.min, Int(UInt32.max) + 1, Int.max] {
            XCTAssertThrowsError(try CapturePCMGeometry.nativeFrameCount(count))
        }
    }

    func testReleasedClockThresholdAndPaddingConserveDeliveredFrames() throws {
        for rate in rates + [3] {
            for delivered in [0, 1024, 48_000] {
                for elapsed in [-1.0, 0, 0.25, 0.5, 0.5001, 1.25, 100] {
                    let plan = try CapturePCMGeometry.delivery(
                        elapsed: elapsed, sampleRate: rate, delivered: delivered, incoming: 4096)
                    let gap = Int(elapsed * rate) - delivered
                    let padding = gap > Int(rate / 2) ? gap : 0
                    XCTAssertEqual(plan.paddingFrameCount, padding)
                    XCTAssertEqual(plan.deliveredFrameCount, delivered + padding + 4096)
                    if padding > 0 { XCTAssertEqual(plan.paddingTimestamp, Double(delivered) / rate) }
                }
            }
        }
    }

    func testClockAndDeliveryOverflowFailBeforePublishingPartialPadding() {
        let invalid: [(Double, Double, Int, Int)] = [
            (.nan, 48_000, 0, 1), (.infinity, 48_000, 0, 1),
            (1, .infinity, 0, 1), (1, 0, 0, 1), (1, -1, 0, 1),
            (.greatestFiniteMagnitude, 48_000, 0, 1),
            (Double(Int.max), 1, 0, 1),
            (Double(UInt32.max) + 1, 1, 0, 1),
            (0, 48_000, Int.max, 1), (-Double(Int.max), 1, 1, 1),
            (0, 48_000, -1, 1), (0, 48_000, 0, -1),
            (0, 48_000, 0, Int(UInt32.max) + 1)
        ]
        for (elapsed, rate, delivered, incoming) in invalid {
            XCTAssertThrowsError(try CapturePCMGeometry.delivery(
                elapsed: elapsed, sampleRate: rate, delivered: delivered, incoming: incoming))
        }
    }

    func testMultipleRouteGapsKeepTheirOriginalTimestampAndExactFrameTotal() throws {
        var delivered = 0
        var padded = 0
        for elapsed in [0.0, 0.1, 3.0, 3.1, 10.0, 10.1] {
            let plan = try CapturePCMGeometry.delivery(
                elapsed: elapsed, sampleRate: 48_000, delivered: delivered, incoming: 4_800)
            if plan.paddingFrameCount > 0 { XCTAssertEqual(plan.paddingTimestamp, Double(delivered) / 48_000) }
            padded += plan.paddingFrameCount
            delivered = plan.deliveredFrameCount
        }
        XCTAssertEqual(delivered, padded + 6 * 4_800)
        XCTAssertEqual(delivered, 489_600)
    }

    func testInvalidWriterRateNeverReachesNativeFormatOrCreatesAnArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, rate) in [Double.nan, .infinity, -.infinity, 0, -1].enumerated() {
            let url = root.appendingPathComponent("invalid-\(index).partial.caf")
            XCTAssertThrowsError(try CaptureFileWriter(url: url, sampleRate: rate))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Exact released algorithm, exercised only over the finite normal matrix.
    /// Invalid conversions are never executed to crash the shared UI host.
}
