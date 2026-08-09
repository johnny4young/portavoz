import PortavozCore
@testable import TranscriptionKit
import XCTest

final class TranscriptionSchedulerTests: XCTestCase {
    /// D7: a live job must complete while a batch job is still holding the
    /// batch slot. If live were queued behind batch this test would hang.
    func testLiveNeverWaitsForBatch() async throws {
        let scheduler = TranscriptionScheduler()
        let gate = SchedulerGate()

        let batch = Task {
            try await scheduler.batch {
                await gate.wait()
                return "batch"
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 1 }

        let live = await scheduler.live { "live" }
        XCTAssertEqual(live, "live")

        await gate.open()
        let batchResult = try await batch.value
        XCTAssertEqual(batchResult, "batch")
    }

    func testBatchSlotIsSerialFIFO() async throws {
        let scheduler = TranscriptionScheduler()
        let gate = SchedulerGate()
        let log = SchedulerRecorder()

        let first = Task {
            try await scheduler.batch {
                await gate.wait()
                await log.add("first-end")
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 1 }

        let second = Task {
            try await scheduler.batch {
                await log.add("second-start")
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 2 }

        let eventsBeforeRelease = await log.events
        XCTAssertTrue(eventsBeforeRelease.isEmpty)

        await gate.open()
        _ = try await first.value
        _ = try await second.value

        let events = await log.events
        XCTAssertEqual(events, ["first-end", "second-start"])
    }

    func testCancelledQueuedBatchIsRemovedBeforeTheActiveJobFinishes() async throws {
        let telemetry = ResourceWorkloadEventRecorder()
        let scheduler = TranscriptionScheduler(telemetry: ResourceWorkloadTelemetry(
            receiver: telemetry.receive))
        let gate = SchedulerGate()
        let log = SchedulerRecorder()

        let first = Task {
            try await scheduler.batch {
                await gate.wait()
                await log.add("first-end")
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 1 }

        let cancelled = Task {
            try await scheduler.batch {
                await log.add("cancelled-job-ran")
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 2 }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("a cancelled queued batch must not reach execution")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await assertEventually { await scheduler.pendingBatchCount == 1 }
        let eventsBeforeRelease = await log.events
        XCTAssertTrue(eventsBeforeRelease.isEmpty)
        XCTAssertEqual(
            telemetry.events.filter(\.isCancelledQueueFinish).count,
            1)
        XCTAssertEqual(
            telemetry.events.filter(\.isExecutionStart).count,
            1,
            "a cancelled waiter must not open an execution span")

        await gate.open()
        _ = try await first.value
        let events = await log.events
        XCTAssertEqual(events, ["first-end"])
    }

    func testAlreadyCancelledBatchNeverRunsItsJob() async throws {
        let scheduler = TranscriptionScheduler()
        let start = SchedulerGate()
        let log = SchedulerRecorder()
        let task = Task {
            await start.wait()
            try await scheduler.batch {
                await log.add("job-ran")
            }
        }
        task.cancel()
        await start.open()

        do {
            _ = try await task.value
            XCTFail("an already-cancelled batch must fail before execution")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let events = await log.events
        let pendingCount = await scheduler.pendingBatchCount
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(pendingCount, 0)
    }

    func testCancellationStormPreservesSurvivorFIFOAndReleasesTheSlot() async throws {
        let scheduler = TranscriptionScheduler()
        let gate = SchedulerGate()
        let log = SchedulerRecorder()
        let active = Task {
            try await scheduler.batch { await gate.wait() }
        }
        await assertEventually { await scheduler.pendingBatchCount == 1 }

        var queued: [Task<Void, Error>] = []
        for index in 0..<32 {
            queued.append(Task {
                try await scheduler.batch { await log.add("job-\(index)") }
            })
            await assertEventually {
                await scheduler.pendingBatchCount == index + 2
            }
        }

        for index in queued.indices where index.isMultiple(of: 2) {
            queued[index].cancel()
        }
        for index in queued.indices where index.isMultiple(of: 2) {
            do {
                _ = try await queued[index].value
                XCTFail("cancelled waiter \(index) reached execution")
            } catch is CancellationError {
                // Expected.
            }
        }
        await assertEventually { await scheduler.pendingBatchCount == 17 }

        await gate.open()
        _ = try await active.value
        for index in queued.indices where !index.isMultiple(of: 2) {
            _ = try await queued[index].value
        }

        let events = await log.events
        XCTAssertEqual(
            events,
            (0..<32).filter { !$0.isMultiple(of: 2) }.map { "job-\($0)" })
        let pendingCount = await scheduler.pendingBatchCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testCancellingRunningBatchCancelsExecutionAndReleasesTheSlot() async throws {
        let telemetry = ResourceWorkloadEventRecorder()
        let scheduler = TranscriptionScheduler(telemetry: ResourceWorkloadTelemetry(
            receiver: telemetry.receive))
        let running = Task {
            try await scheduler.batch {
                try await Task.sleep(for: .seconds(30))
            }
        }
        await assertEventually {
            telemetry.events.contains(where: \.isExecutionStart)
        }

        running.cancel()
        do {
            _ = try await running.value
            XCTFail("running batch cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }
        await assertEventually { await scheduler.pendingBatchCount == 0 }

        XCTAssertEqual(
            telemetry.events.filter(\.isCancelledExecutionFinish).count,
            1)
        let next = try await scheduler.batch { "next" }
        XCTAssertEqual(next, "next")
    }

    func testTelemetryClassifiesLiveAndBatchLanes() async throws {
        let recorder = ResourceWorkloadEventRecorder()
        let scheduler = TranscriptionScheduler(telemetry: ResourceWorkloadTelemetry(
            receiver: recorder.receive))

        _ = await scheduler.live { "live" }
        _ = try await scheduler.batch { "batch" }

        let started = recorder.events.compactMap { event -> ResourceWorkloadDescriptor? in
            guard case .started(let span) = event else { return nil }
            return span.descriptor
        }
        XCTAssertEqual(
            started,
            [
                ResourceWorkloadDescriptor(
                    workloadClass: .liveInteractive,
                    kind: .liveTranscription,
                    operation: .execute),
                ResourceWorkloadDescriptor(
                    workloadClass: .postCapture,
                    kind: .qualityTranscription,
                    operation: .queueWait),
                ResourceWorkloadDescriptor(
                    workloadClass: .postCapture,
                    kind: .qualityTranscription,
                    operation: .execute)
            ])
    }
}

private actor SchedulerGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor SchedulerRecorder {
    private(set) var events: [String] = []

    func add(_ event: String) {
        events.append(event)
    }
}

private func assertEventually(
    timeout: Duration = .seconds(2),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    if !(await condition()) {
        XCTFail("condition was not reached before timeout", file: file, line: line)
    }
}

private extension ResourceWorkloadEvent {
    var isCancelledQueueFinish: Bool {
        guard case .finished(let span, outcome: .cancelled) = self else {
            return false
        }
        return span.descriptor.operation == .queueWait
    }

    var isExecutionStart: Bool {
        guard case .started(let span) = self else { return false }
        return span.descriptor.operation == .execute
    }

    var isCancelledExecutionFinish: Bool {
        guard case .finished(let span, outcome: .cancelled) = self else {
            return false
        }
        return span.descriptor.operation == .execute
    }
}
