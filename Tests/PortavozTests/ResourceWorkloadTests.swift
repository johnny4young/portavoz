import Foundation
import PortavozCore
import XCTest

final class ResourceWorkloadTests: XCTestCase {
    func testTaxonomyIsClosedAndStable() {
        XCTAssertEqual(
            ResourceWorkloadClass.allCases.map(\.rawValue),
            [
                "recordingCritical", "liveInteractive", "userInitiated",
                "postCapture", "maintenance",
            ])
        XCTAssertEqual(
            ResourceWorkloadKind.allCases.map(\.rawValue),
            [
                "audioCapture", "liveTranscription", "qualityTranscription",
                "speakerDiarization", "languageInference", "searchIndex",
                "librarySync", "waveform", "uiProjection", "mediaExport",
                "supportExport",
            ])
        XCTAssertEqual(
            ResourceWorkloadOperation.allCases.map(\.rawValue),
            ["queueWait", "execute", "prepare", "load", "release"])
    }

    func testMeasureEmitsOneMatchedCompletedSpan() async throws {
        let recorder = ResourceWorkloadEventRecorder()
        let telemetry = ResourceWorkloadTelemetry(receiver: recorder.receive)
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .searchIndex,
            operation: .execute)

        let value = await telemetry.measure(descriptor) { 42 }

        XCTAssertEqual(value, 42)
        let events = recorder.events
        guard case .started(let started) = try XCTUnwrap(events.first),
              case .finished(let finished, let outcome) = try XCTUnwrap(events.last)
        else {
            return XCTFail("Expected one matched telemetry interval")
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(started, finished)
        XCTAssertEqual(started.descriptor, descriptor)
        XCTAssertEqual(outcome, .completed)
    }

    func testMeasureClassifiesCancellationWithoutErrorPayload() async {
        let recorder = ResourceWorkloadEventRecorder()
        let telemetry = ResourceWorkloadTelemetry(receiver: recorder.receive)
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .languageInference,
            operation: .execute)

        do {
            _ = try await telemetry.measure(descriptor) {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        guard case .finished(_, let outcome) = recorder.events.last else {
            return XCTFail("Expected terminal event")
        }
        XCTAssertEqual(outcome, .cancelled)
    }

    func testRelayUsesLatestInstalledReceiver() {
        let first = ResourceWorkloadEventRecorder()
        let second = ResourceWorkloadEventRecorder()
        let relay = ResourceWorkloadTelemetryRelay(
            telemetry: ResourceWorkloadTelemetry(receiver: first.receive))
        let telemetry = relay.telemetry
        let descriptor = ResourceWorkloadDescriptor(
            workloadClass: .postCapture,
            kind: .qualityTranscription,
            operation: .load)

        let firstSpan = telemetry.begin(descriptor)
        telemetry.finish(firstSpan, outcome: .completed)
        relay.install(ResourceWorkloadTelemetry(receiver: second.receive))
        let secondSpan = telemetry.begin(descriptor)
        telemetry.finish(secondSpan, outcome: .failed)

        XCTAssertEqual(first.events.count, 2)
        XCTAssertEqual(second.events.count, 2)
    }
}

final class ResourceWorkloadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ResourceWorkloadEvent] = []

    var events: [ResourceWorkloadEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: ResourceWorkloadEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
