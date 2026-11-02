import XCTest

@MainActor
final class ControlledTestSleepTests: XCTestCase {
    func testCallCountWaiterOutlastsALateCall() async throws {
        let sleep = ControlledTestSleep()
        async let started = sleep.waitUntilCallCount(1)
        await yieldLongerThanTheOldPollingBudget()

        let call = Task { try await sleep.wait(for: .milliseconds(200)) }
        let callStarted = await started
        let resumed = await sleep.resumeCall(at: 0)
        if !resumed { call.cancel() }
        _ = try? await call.value
        XCTAssertTrue(callStarted)
        XCTAssertTrue(resumed)
    }

    func testCancellationWaiterOutlastsALateCancellation() async throws {
        let sleep = ControlledTestSleep()
        let call = Task { try await sleep.wait(for: .milliseconds(200)) }
        let callStarted = await sleep.waitUntilCallCount(1)
        async let cancelled = sleep.waitUntilCancellationCount(1)
        await yieldLongerThanTheOldPollingBudget()

        call.cancel()
        let cancellationObserved = await cancelled
        XCTAssertTrue(callStarted)
        XCTAssertTrue(cancellationObserved)
        do {
            try await call.value
            XCTFail("a cancelled call must throw")
        } catch is CancellationError {}
    }

    private func yieldLongerThanTheOldPollingBudget() async {
        for _ in 0..<50_000 { await Task.yield() }
    }
}
