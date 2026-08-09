import Foundation
import PortavozCore

/// Two-slot work scheduler enforcing the D7 rule: *lo vivo nunca espera a
/// lo batch*. Live jobs run immediately, always — there is no live queue.
/// Batch jobs (file transcription, re-passes) share one serial slot at
/// utility priority, so they interleave politely with live inference on
/// the ANE instead of racing it. Pattern borrowed from MacParakeet
/// (studied, not ported — it's GPL).
public actor TranscriptionScheduler {
    private struct BatchWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var batchBusy = false
    private var batchWaiters: [BatchWaiter] = []
    private let telemetry: ResourceWorkloadTelemetry

    public init(telemetry: ResourceWorkloadTelemetry = .disabled) {
        self.telemetry = telemetry
    }

    /// Runs a live job right now on the caller's task. Exists as an explicit
    /// lane so call sites read as scheduler decisions, and as the seam where
    /// live-lane instrumentation lands later.
    public func live<Result: Sendable>(
        _ job: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await telemetry.measure(ResourceWorkloadDescriptor(
            workloadClass: .liveInteractive,
            kind: .liveTranscription,
            operation: .execute
        )) {
            try await job()
        }
    }

    /// Waits for the single batch slot (FIFO), then runs the job in a child
    /// task at `.utility` priority so a concurrent live job wins every
    /// scheduling race.
    public func batch<Result: Sendable>(
        workloadClass: ResourceWorkloadClass = .postCapture,
        _ job: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let queueSpan = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: workloadClass,
            kind: .qualityTranscription,
            operation: .queueWait))
        do {
            try Task.checkCancellation()
            try await acquireBatchSlot()
        } catch {
            telemetry.finish(
                queueSpan,
                outcome: ResourceWorkloadOutcome(error: error))
            throw error
        }
        // Slot handoff and caller cancellation can race. Install cleanup
        // before the second check so a cancelled handoff cannot strand the
        // serial lane or reach the detached job.
        defer { releaseBatchSlot() }
        do {
            try Task.checkCancellation()
            telemetry.finish(queueSpan, outcome: .completed)
        } catch {
            telemetry.finish(
                queueSpan,
                outcome: ResourceWorkloadOutcome(error: error))
            throw error
        }

        let executionSpan = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: workloadClass,
            kind: .qualityTranscription,
            operation: .execute))
        let task = Task.detached(priority: .utility) {
            try await job()
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            telemetry.finish(executionSpan, outcome: .completed)
            return value
        } catch {
            telemetry.finish(
                executionSpan,
                outcome: ResourceWorkloadOutcome(error: error))
            throw error
        }
    }

    /// Queued + running batch work, exposed internally for deterministic tests.
    var pendingBatchCount: Int { batchWaiters.count + (batchBusy ? 1 : 0) }

    private func acquireBatchSlot() async throws {
        if !batchBusy {
            batchBusy = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                batchWaiters.append(BatchWaiter(
                    id: id,
                    continuation: continuation))
            }
        } onCancel: {
            // The handler is synchronous and nonisolated. Its task cannot
            // mutate this actor until the continuation closure above has
            // either enqueued the waiter or the slot has already handed off.
            Task { await self.cancelBatchWaiter(id: id) }
        }
    }

    private func cancelBatchWaiter(id: UUID) {
        guard let index = batchWaiters.firstIndex(where: { $0.id == id }) else {
            // A concurrent release may already have handed over the slot. The
            // resumed caller's post-acquire cancellation check owns that race.
            return
        }
        let waiter = batchWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseBatchSlot() {
        if batchWaiters.isEmpty {
            batchBusy = false
        } else {
            batchWaiters.removeFirst().continuation.resume()
        }
    }
}
