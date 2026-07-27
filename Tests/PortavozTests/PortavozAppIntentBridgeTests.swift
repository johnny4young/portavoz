import XCTest

@testable import portavoz_app

final class PortavozAppIntentBridgeTests: XCTestCase {
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
