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
}
