@testable import ApplicationKit
import Foundation
import os
import XCTest

final class AskAnswerDeadlineTests: XCTestCase {
    func testOnTimeValueDoesNotClosePublication() async throws {
        let clock = AskManualClock()
        let closed = OSAllocatedUnfairLock(initialState: false)
        let value = try await withAskTimeout(
            AskAnswerDeadline(after: .seconds(8), clock: clock.clock),
            onTimeout: { closed.withLock { $0 = true } }
        ) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(closed.withLock { $0 })
    }

    func testOnTimeProviderFailureDoesNotBecomeTimeout() async throws {
        let clock = AskManualClock()
        let closed = OSAllocatedUnfairLock(initialState: false)
        do {
            let _: Int = try await withAskTimeout(
                AskAnswerDeadline(after: .seconds(8), clock: clock.clock),
                onTimeout: { closed.withLock { $0 = true } }
            ) { throw DeadlineTestError.provider }
            XCTFail("provider failure must escape")
        } catch DeadlineTestError.provider {
            XCTAssertFalse(closed.withLock { $0 })
        }
    }

    func testCancellationDuringTimeoutClosureRemainsCancellation() async throws {
        let clock = AskManualClock()
        let task = Task {
            try await withAskTimeout(
                AskAnswerDeadline(after: .seconds(8), clock: clock.clock),
                onTimeout: { withUnsafeCurrentTask { $0?.cancel() } }
            ) {
                clock.advance(by: .seconds(8))
                return 42
            }
        }
        do {
            _ = try await task.value
            XCTFail("suspending timeout cleanup must not hide caller cancellation")
        } catch is CancellationError {
            // The timeout callback runs in the calling task.
        }
    }

    func testLateValueAndErrorTimeOutWhileTimerCannotWake() async throws {
        for shouldThrow in [false, true] {
            let clock = AskManualClock()
            let closeCount = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await withAskTimeout(
                    AskAnswerDeadline(after: .seconds(8), clock: clock.clock),
                    onTimeout: { closeCount.withLock { $0 += 1 } }
                ) {
                    clock.advance(by: .seconds(8))
                    if shouldThrow { throw DeadlineTestError.provider }
                    return 42
                }
                XCTFail("late work must not win merely because the timer is parked")
            } catch is AskTimeoutError {
                XCTAssertEqual(closeCount.withLock { $0 }, 1)
            }
        }
    }

    func testExpiredRequestDoesNotStartProvider() async throws {
        let clock = AskManualClock()
        let deadline = AskAnswerDeadline(after: .seconds(8), clock: clock.clock)
        clock.advance(by: .seconds(8))
        let called = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try await withAskTimeout(deadline, onTimeout: {}) {
                called.withLock { $0 = true }
                return 42
            }
            XCTFail("an expired request must time out")
        } catch is AskTimeoutError {
            XCTAssertFalse(called.withLock { $0 })
        }
    }

    func testCancellationWinsOverAnAlreadyExpiredDeadline() async throws {
        let clock = AskManualClock()
        let deadline = AskAnswerDeadline(after: .seconds(8), clock: clock.clock)
        let called = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            clock.advance(by: .seconds(8))
            return try await withAskTimeout(deadline, onTimeout: {}) {
                called.withLock { $0 = true }
                return 42
            }
        }
        do {
            _ = try await task.value
            XCTFail("caller cancellation must remain cancellation")
        } catch is CancellationError {
            XCTAssertFalse(called.withLock { $0 })
        }
    }

    func testCancellationDuringChildTeardownOverridesValueAndProviderError() async throws {
        for shouldThrow in [false, true] {
            let clock = AskManualClock()
            let start = AsyncStream<Void>.makeStream()
            let timerStarted = AsyncStream<Void>.makeStream()
            let caller = OSAllocatedUnfairLock<Task<Int, Error>?>(initialState: nil)
            let controlledClock = AskAnswerClock(now: clock.clock.now, sleepUntil: { _ in
                timerStarted.continuation.yield(())
                do {
                    try await AskManualClock.parkUntilCancelled()
                } catch {
                    caller.withLock { $0?.cancel() }
                    throw error
                }
            })
            let task = Task<Int, Error> {
                for await _ in start.stream { break }
                return try await withAskTimeout(
                    AskAnswerDeadline(after: .seconds(8), clock: controlledClock),
                    onTimeout: {}
                ) {
                    for await _ in timerStarted.stream { break }
                    if shouldThrow { throw DeadlineTestError.provider }
                    return 42
                }
            }
            caller.withLock { $0 = task }
            start.continuation.yield(())
            do {
                _ = try await task.value
                XCTFail("cancellation during structured teardown must escape")
            } catch is CancellationError {
                // Both successful and failing provider completions are fenced.
            } catch {
                XCTFail("caller cancellation was hidden by \(error)")
            }
            caller.withLock { $0 = nil }
            start.continuation.finish()
            timerStarted.continuation.finish()
        }
    }

    func testTimerUsesFixedInstantAndClosesBeforeProviderCancellation() async throws {
        let clock = AskManualClock()
        let started = AsyncStream<Void>.makeStream()
        let closed = OSAllocatedUnfairLock(initialState: false)
        let sawClosedOnCancellation = OSAllocatedUnfairLock(initialState: false)
        let initial = clock.clock.now()
        let timerInstant = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        let controlledClock = AskAnswerClock(now: clock.clock.now, sleepUntil: { instant in
            timerInstant.withLock { $0 = instant }
            for await _ in started.stream { break }
            clock.advance(by: .seconds(8))
        })
        let deadline = AskAnswerDeadline(after: .seconds(8), clock: controlledClock)
        // The child must not start a fresh eight-second budget from this point.
        clock.advance(by: .seconds(1))
        do {
            _ = try await withAskTimeout(
                deadline, onTimeout: { closed.withLock { $0 = true } }
            ) {
                started.continuation.yield(())
                do {
                    try await AskManualClock.parkUntilCancelled()
                } catch {
                    sawClosedOnCancellation.withLock { $0 = closed.withLock { $0 } }
                }
                return 42
            }
            XCTFail("timer must reject the cancellation-ignoring value")
        } catch is AskTimeoutError {
            XCTAssertEqual(timerInstant.withLock { $0 }, initial.advanced(by: .seconds(8)))
            XCTAssertTrue(sawClosedOnCancellation.withLock { $0 })
        }
        started.continuation.finish()
    }

    func testProgressiveGateRejectsSnapshotsAndFinalizationAtExactDeadline() async throws {
        let clock = AskManualClock()
        let deadline = AskAnswerDeadline(after: .seconds(8), clock: clock.clock)
        let gate = AskProgressiveUpdateGate(limit: 4, source: .library)
        let first = await gate.admitAnswer(AskAnswerUpdate(text: "On time"), deadline: deadline)
        XCTAssertEqual(first?.text, "On time")
        clock.advance(by: .seconds(8))
        let late = await gate.admitAnswer(AskAnswerUpdate(text: "On time but late."), deadline: deadline)
        XCTAssertNil(late)
        do {
            _ = try await gate.finalizeAnswer("On time but late.", deadline: deadline)
            XCTFail("final-only output also needs deadline admission")
        } catch is AskTimeoutError {
            // Exact boundary is excluded, even with no timer task.
        }
    }
}

private enum DeadlineTestError: Error { case provider }

/// A monotonic clock whose timer deliberately never wakes before cancellation.
/// Providers advance time synchronously, so tests expose scheduler starvation
/// without sleeps, retries, global state, or dependence on machine load.
final class AskManualClock: Sendable {
    private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    var clock: AskAnswerClock {
        AskAnswerClock(
            now: { self.instant.withLock { $0 } },
            sleepUntil: { _ in try await Self.parkUntilCancelled() })
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        instant.withLock { $0 = $0.advanced(by: duration) }
    }

    static func parkUntilCancelled() async throws {
        let pair = AsyncStream<Void>.makeStream()
        defer { pair.continuation.finish() }
        var iterator = pair.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }
}
