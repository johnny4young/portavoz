import Foundation

/// Two-slot work scheduler enforcing the D7 rule: *lo vivo nunca espera a
/// lo batch*. Live jobs run immediately, always — there is no live queue.
/// Batch jobs (file transcription, re-passes) share one serial slot at
/// utility priority, so they interleave politely with live inference on
/// the ANE instead of racing it. Pattern borrowed from MacParakeet
/// (studied, not ported — it's GPL).
public actor TranscriptionScheduler {
    private var batchBusy = false
    private var batchWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs a live job right now on the caller's task. Exists as an explicit
    /// lane so call sites read as scheduler decisions, and as the seam where
    /// live-lane instrumentation lands later.
    public func live<Result: Sendable>(
        _ job: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await job()
    }

    /// Waits for the single batch slot (FIFO), then runs the job in a child
    /// task at `.utility` priority so a concurrent live job wins every
    /// scheduling race.
    public func batch<Result: Sendable>(
        _ job: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquireBatchSlot()
        defer { releaseBatchSlot() }

        let task = Task.detached(priority: .utility) {
            try await job()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func acquireBatchSlot() async {
        if !batchBusy {
            batchBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            batchWaiters.append(continuation)
        }
    }

    private func releaseBatchSlot() {
        if batchWaiters.isEmpty {
            batchBusy = false
        } else {
            batchWaiters.removeFirst().resume()
        }
    }
}
