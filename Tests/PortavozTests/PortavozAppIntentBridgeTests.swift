import PortavozCore
import XCTest

@testable import portavoz_app

final class PortavozAppIntentBridgeTests: XCTestCase {
    @MainActor
    func testPendingRequestCanBeRepublishedAfterServicesBecomeReady() {
        _ = PortavozAppIntentBridge.consumeStartRecordingRequest()
        var deliveries = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.startRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { deliveries += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStartRecordingRequest()
        }

        PortavozAppIntentBridge.requestStartRecording()
        PortavozAppIntentBridge.notifyPendingStartRecordingRequest()

        XCTAssertEqual(deliveries, 2)
        XCTAssertTrue(PortavozAppIntentBridge.consumeStartRecordingRequest())
    }

    @MainActor
    func testStartRecordingIntentHandsOffExactlyOnceInsideItsOwningProcess() async throws {
        // Drain any request left by a failed test before proving one-shot
        // delivery. The bridge is process-scoped by design.
        _ = PortavozAppIntentBridge.consumeStartRecordingRequest()

        _ = try await StartRecordingIntent().perform()

        XCTAssertTrue(PortavozAppIntentBridge.consumeStartRecordingRequest())
        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStartRecordingRequest(),
            "one invocation must not start a second recording later")
    }

    @MainActor
    func testPendingStopRequestCanBeRepublishedAfterServicesBecomeReady() {
        _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        var deliveries = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.stopRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { deliveries += 1 }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        }

        XCTAssertEqual(PortavozAppIntentBridge.requestStopRecording(), .queued)
        PortavozAppIntentBridge.notifyPendingStopRecordingRequest()

        XCTAssertEqual(deliveries, 2)
        XCTAssertTrue(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted))
        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted),
            "one request must never be accepted twice")
    }

    @MainActor
    func testStopRecordingIntentReturnsTheDelegateDispositionExactlyOnce() async throws {
        _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        let observer = NotificationCenter.default.addObserver(
            forName: PortavozAppIntentBridge.stopRecordingRequested,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                XCTAssertTrue(PortavozAppIntentBridge.consumeStopRecordingRequest(
                    as: .accepted))
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = PortavozAppIntentBridge.consumeStopRecordingRequest(as: .queued)
        }

        _ = try await StopRecordingIntent().perform()

        XCTAssertFalse(
            PortavozAppIntentBridge.consumeStopRecordingRequest(as: .accepted),
            "perform() must not leave a second stop behind after acceptance")
    }

    @MainActor
    func testStopRecordingDispositionNamesEveryLifecycleRecovery() {
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .idle,
                stopTaskIsRunning: false),
            .noActiveRecording)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .preparing,
                stopTaskIsRunning: false),
            .recordingIsPreparing)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .recording,
                stopTaskIsRunning: false),
            .accepted)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .processing("Saving"),
                stopTaskIsRunning: false),
            .alreadyStopping)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .done(MeetingID()),
                stopTaskIsRunning: false),
            .noActiveRecording)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .failed("Failed"),
                stopTaskIsRunning: false),
            .recoveryRequired)
        XCTAssertEqual(
            PortavozAppDelegate.stopRecordingIntentDisposition(
                for: .recording,
                stopTaskIsRunning: true),
            .alreadyStopping,
            "the in-flight fence must win before another stop can schedule")
    }

}
