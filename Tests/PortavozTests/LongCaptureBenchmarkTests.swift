import AudioCaptureKit
import XCTest
@testable import portavoz_cli

final class LongCaptureBenchmarkTests: XCTestCase {
    func testOptionsDefaultToCanonicalThreeHourRun() throws {
        let options = try CaptureBenchmarkOptions(arguments: [])

        XCTAssertEqual(options.durationSeconds, 10_800)
        XCTAssertEqual(options.chunkFrames, 4_800)
        XCTAssertNil(options.sourceCommit)
        XCTAssertNil(options.output)
    }

    func testOptionsRejectOutOfContractValuesAndUnknownFlags() {
        XCTAssertThrowsError(try CaptureBenchmarkOptions(
            arguments: ["--duration-seconds", "0"])) { error in
                XCTAssertEqual(error as? CaptureBenchmarkError, .invalidDuration)
            }
        XCTAssertThrowsError(try CaptureBenchmarkOptions(
            arguments: ["--chunk-frames", "16001"])) { error in
                XCTAssertEqual(error as? CaptureBenchmarkError, .invalidChunkFrames)
            }
        XCTAssertThrowsError(try CaptureBenchmarkOptions(
            arguments: ["--output"])) { error in
                XCTAssertEqual(
                    error as? CaptureBenchmarkError,
                    .missingOptionValue("--output"))
            }
        XCTAssertThrowsError(try CaptureBenchmarkOptions(
            arguments: ["--source-commit", "ABC"])) { error in
                XCTAssertEqual(error as? CaptureBenchmarkError, .invalidSourceCommit)
            }
        XCTAssertThrowsError(try CaptureBenchmarkOptions(
            arguments: ["--invented"])) { error in
                XCTAssertEqual(
                    error as? CaptureBenchmarkError,
                    .unknownOption("--invented"))
            }
    }

    func testAcceleratedDualChannelRunConservesEveryFrameThroughPublication() async throws {
        let options = try CaptureBenchmarkOptions(arguments: [
            "--duration-seconds", "1",
            "--chunk-frames", "7000",
        ])

        let report = try await CaptureBenchmark.run(options: options)

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.contentSource, "synthetic-only")
        XCTAssertNil(report.sourceCommit)
        XCTAssertEqual(report.configuration.requestedDurationSeconds, 1)
        XCTAssertEqual(report.configuration.expectedFramesPerChannel, 16_000)
        XCTAssertEqual(report.configuration.logicalChunksPerChannel, 3)
        XCTAssertFalse(report.configuration.canonicalThreeHourRun)
        XCTAssertEqual(report.channels.map(\.id), ["microphone", "system"])
        XCTAssertTrue(report.channels.allSatisfy {
            $0.expectedFrames == 16_000
                && $0.acceptedFrames == 16_000
                && $0.publishedFrames == 16_000
                && $0.durationSeconds == 1
                && $0.byteCount > 0
                && $0.healthStatus == "healthy"
        })
        XCTAssertTrue(report.result.passed)
        XCTAssertEqual(report.result.driftFrames, 0)
        XCTAssertGreaterThanOrEqual(
            report.result.peakHeapBytesInUse,
            report.result.baselineHeapBytesInUse)
        XCTAssertLessThanOrEqual(
            report.result.incrementalPeakHeapBytesInUse,
            report.result.maximumIncrementalHeapBytesInUse)
        XCTAssertEqual(
            report.result.maximumIncrementalHeapBytesInUse,
            16 * 1_024 * 1_024)
    }
}
