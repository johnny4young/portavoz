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

    func testMainActorWaiterOutlastsALateEvent() async {
        let events = MainActorTestEvents()
        let counter = MainActorCounter()
        let waiter = Task { await events.waitUntil { counter.value >= 1 } }
        await yieldLongerThanTheOldPollingBudget()

        counter.value = 1
        events.signal()
        let arrived = await waiter.value
        XCTAssertTrue(arrived)
    }

    func testACallCancelledBeforeItSuspendsStillCounts() async {
        let sleep = ControlledTestSleep()
        async let counted = sleep.waitUntilCallCount(1)
        await yieldLongerThanTheOldPollingBudget()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await sleep.wait(for: .milliseconds(200))
        }
        _ = try? await call.value
        let started = ContinuousClock.now
        let observed = await counted
        XCTAssertTrue(observed)
        XCTAssertLessThan(ContinuousClock.now - started, ControlledTestSleep.hangGuard / 2)
    }

    func testPollingStopsWhenTheTestIsCancelled() async {
        let poll = Task { @MainActor in await TestPolling.until { false } }
        let started = ContinuousClock.now
        poll.cancel()
        let reached = await poll.value
        XCTAssertFalse(reached)
        XCTAssertLessThan(ContinuousClock.now - started, ControlledTestSleep.hangGuard / 2)
    }

    private func yieldLongerThanTheOldPollingBudget() async {
        for _ in 0..<50_000 { await Task.yield() }
    }
}

@MainActor
private final class MainActorCounter {
    var value = 0
}
