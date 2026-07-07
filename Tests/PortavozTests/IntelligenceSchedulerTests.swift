import Foundation
import XCTest

@testable import IntelligenceKit

/// The scheduler is pure concurrency (no FM dependency), so every property
/// that makes the copilot's latency budget attainable is testable here.
final class IntelligenceSchedulerTests: XCTestCase {
    /// Records completion order across concurrent jobs.
    private actor Log {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    /// A gate the test opens to let a running job finish.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func waitUntil(
        _ timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSingleFlightSerializesJobs() async throws {
        let scheduler = IntelligenceScheduler()
        let log = Log()
        let gate = Gate()

        let first = Task {
            try await scheduler.run(.background) {
                await gate.wait()
                await log.append("first")
            }
        }
        await waitUntil { await scheduler.pendingCount == 1 }

        let second = Task {
            try await scheduler.run(.background) {
                await log.append("second")
            }
        }
        await waitUntil { await scheduler.pendingCount == 2 }

        // Second cannot run while first holds the slot.
        let entriesBefore = await log.entries
        XCTAssertTrue(entriesBefore.isEmpty)

        await gate.open()
        _ = try await first.value
        _ = try await second.value
        let entries = await log.entries
        XCTAssertEqual(entries, ["first", "second"])
    }

    func testInteractiveJumpsQueuedBackground() async throws {
        let scheduler = IntelligenceScheduler()
        let log = Log()
        let gate = Gate()

        let running = Task {
            try await scheduler.run(.background) { await gate.wait() }
        }
        await waitUntil { await scheduler.pendingCount == 1 }

        let queuedBackground = Task {
            try await scheduler.run(.background) { await log.append("background") }
        }
        await waitUntil { await scheduler.pendingCount == 2 }
        let interactive = Task {
            try await scheduler.run(.interactive) { await log.append("interactive") }
        }
        await waitUntil { await scheduler.pendingCount == 3 }

        await gate.open()
        _ = try await running.value
        _ = try await interactive.value
        _ = try await queuedBackground.value
        let entries = await log.entries
        XCTAssertEqual(entries, ["interactive", "background"])
    }

    func testFIFOWithinSamePriority() async throws {
        let scheduler = IntelligenceScheduler()
        let log = Log()
        let gate = Gate()

        let running = Task {
            try await scheduler.run(.background) { await gate.wait() }
        }
        await waitUntil { await scheduler.pendingCount == 1 }

        var queued: [Task<Void, Error>] = []
        for index in 0..<3 {
            queued.append(
                Task {
                    try await scheduler.run(.live) { await log.append("job\(index)") }
                })
            await waitUntil { await scheduler.pendingCount == 2 + index }
        }

        await gate.open()
        _ = try await running.value
        for task in queued { _ = try await task.value }
        let entries = await log.entries
        XCTAssertEqual(entries, ["job0", "job1", "job2"])
    }

    func testLatestWinsKeyReplacesQueuedJob() async throws {
        let scheduler = IntelligenceScheduler()
        let log = Log()
        let gate = Gate()

        let running = Task {
            try await scheduler.run(.background) { await gate.wait() }
        }
        await waitUntil { await scheduler.pendingCount == 1 }

        let stale = Task {
            try await scheduler.run(.live, key: "detect") { await log.append("stale") }
        }
        await waitUntil { await scheduler.pendingCount == 2 }
        let fresh = Task {
            try await scheduler.run(.live, key: "detect") { await log.append("fresh") }
        }
        await waitUntil { await scheduler.pendingCount == 2 }  // replaced, not added

        do {
            _ = try await stale.value
            XCTFail("stale job should have been replaced")
        } catch is CancellationError {
            // expected
        }

        await gate.open()
        _ = try await running.value
        _ = try await fresh.value
        let entries = await log.entries
        XCTAssertEqual(entries, ["fresh"])
    }

    func testCallerCancellationDequeues() async throws {
        let scheduler = IntelligenceScheduler()
        let gate = Gate()

        let running = Task {
            try await scheduler.run(.background) { await gate.wait() }
        }
        await waitUntil { await scheduler.pendingCount == 1 }

        let cancelled = Task {
            try await scheduler.run(.interactive) { XCTFail("must never run") }
        }
        await waitUntil { await scheduler.pendingCount == 2 }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}

        await waitUntil { await scheduler.pendingCount == 1 }
        await gate.open()
        _ = try await running.value
        let pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testThrowingJobReleasesSlot() async throws {
        struct Boom: Error {}
        let scheduler = IntelligenceScheduler()

        do {
            _ = try await scheduler.run(.interactive) { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}

        // The slot must be free for the next job.
        let result = try await scheduler.run(.background) { "ok" }
        XCTAssertEqual(result, "ok")
        let pending = await scheduler.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testInteractiveInterleavesBetweenChainSteps() async throws {
        let scheduler = IntelligenceScheduler()
        let log = Log()
        let stepGate = Gate()

        // A background "map-reduce chain": one scheduler.run per step —
        // the slot is released between steps.
        let chain = Task {
            try await scheduler.run(.background) {
                await log.append("step1")
                await stepGate.wait()
            }
            try await scheduler.run(.background) { await log.append("step2") }
        }
        await waitUntil { await scheduler.pendingCount >= 1 }

        let interactive = Task {
            try await scheduler.run(.interactive) { await log.append("answer") }
        }
        await waitUntil { await scheduler.pendingCount == 2 }

        await stepGate.open()
        _ = try await interactive.value
        _ = try await chain.value
        let entries = await log.entries
        // The interactive answer lands BETWEEN the chain's steps.
        XCTAssertEqual(entries, ["step1", "answer", "step2"])
    }
}
