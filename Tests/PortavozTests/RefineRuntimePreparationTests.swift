import ApplicationKit
import Foundation
import XCTest
@testable import portavoz_app

@MainActor
final class RefineRuntimePreparationTests: XCTestCase {
    func testPreparationPublishesMarkerOnlyAfterNonemptyInference() async throws {
        let output = try makeOutputURL()
        try await BenchRefineRuntimePreparation.run(
            outputURL: output, timeout: .seconds(1)
        ) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            await Task.yield()
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            return 14
        }
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            BenchResourceLaunchProbe.Marker.refineRuntimePrepared.rawValue)
    }

    func testEmptyInferenceCannotPublishPreparation() async throws {
        let output = try makeOutputURL()
        for count in [0, -1] {
            do {
                try await BenchRefineRuntimePreparation.run(
                    outputURL: output, timeout: .seconds(1)
                ) { count }
                XCTFail("Empty inference must fail closed")
            } catch {
                XCTAssertEqual(
                    error as? BenchRefineResourcePreparationError, .emptyDraft)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testFailedInferenceCannotPublishPreparation() async throws {
        let output = try makeOutputURL()
        do {
            try await BenchRefineRuntimePreparation.run(
                outputURL: output, timeout: .seconds(1)
            ) { throw CancellationError() }
            XCTFail("Failed inference must fail closed")
        } catch {
            guard case .operationFailed = error as? BenchResourceTimedOperationError else {
                return XCTFail("Expected the bounded operation failure")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTimedOutInferenceCannotPublishALateMarker() async throws {
        let output = try makeOutputURL()
        do {
            try await BenchRefineRuntimePreparation.run(
                outputURL: output, timeout: .milliseconds(20)
            ) {
                // Deliberately return a value even when cancellation wakes us.
                try? await Task.sleep(for: .seconds(60))
                return 14
            }
            XCTFail("Timed-out inference must fail closed")
        } catch {
            XCTAssertEqual(error as? BenchResourceTimedOperationError, .timedOut)
        }
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSummaryPreparationRequiresSuccessfulPersistence() async throws {
        let output = try makeOutputURL()
        let rejected: [SummaryRegenerationResult] = [
            .completed(persisted: false), .unchanged(version: 1),
            .unavailable(.mlxModelNotDownloaded), .generationFailed(.silent),
        ]
        for result in rejected {
            XCTAssertThrowsError(try BenchSummaryRuntimePreparation.publish(
                result: result, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        try BenchSummaryRuntimePreparation.publish(
            result: .completed(persisted: true), to: output)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            BenchResourceLaunchProbe.Marker.summaryRuntimePrepared.rawValue)
    }

    func testSummaryPreparationMarkerIsExplicitAndAbsolute() async throws {
        let base = ["Portavoz", "--bench-resource-summary"]
        XCTAssertNil(try BenchSummaryResourceConfiguration.requested(
            arguments: base)?.preparationOutputURL)
        for invalid in [
            ["--bench-resource-preparation-marker"],
            ["--bench-resource-preparation-marker", "relative"],
            ["--bench-resource-preparation-marker", "/tmp/one",
             "--bench-resource-preparation-marker", "/tmp/two"],
        ] {
            XCTAssertThrowsError(try BenchSummaryResourceConfiguration.requested(
                arguments: base + invalid))
        }
        let configuration = try XCTUnwrap(BenchSummaryResourceConfiguration.requested(
            arguments: base + ["--bench-resource-preparation-marker", "/tmp/summary-ready"]))
        XCTAssertEqual(configuration.preparationOutputURL?.path, "/tmp/summary-ready")
    }

    private func makeOutputURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("prepared")
    }
}
