import Foundation

/// Owns the optional rolling-summary cadence for one recording lifecycle.
///
/// Caption, diarization, and note bursts collapse into one pending refresh.
/// A cycle already in progress is never overlapped; if new material arrives
/// while it runs, one later cycle survives. The operation reports retained
/// backlog explicitly so bounded oldest-first batches continue without a
/// permanent idle poll.
@MainActor
final class LiveSummaryWorkCoordinator {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Operation = @MainActor @Sendable () async -> Bool

    private let interval: Duration
    private let sleep: Sleep
    private let operation: Operation
    private var worker: Task<Void, Never>?
    private var pending = false

    init(
        interval: Duration = .seconds(40),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        operation: @escaping Operation
    ) {
        self.interval = interval
        self.sleep = sleep
        self.operation = operation
    }

    var isRunning: Bool { worker != nil }
    var hasPendingWork: Bool { pending }

    func request() {
        pending = true
        startWorkerIfNeeded()
    }

    func cancel() {
        pending = false
        worker?.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, pending else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, pending {
            do {
                try await sleep(interval)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }

            // Every signal received before execution is represented by this
            // newest-state pass. Signals arriving during the awaited work set
            // the bit again and survive for one later pass.
            pending = false
            let hasBacklog = await operation()
            guard !Task.isCancelled else { break }
            pending = pending || hasBacklog
        }

        worker = nil
        // A fresh recording may request work while a cancelled provider is
        // still unwinding. Keep it behind the old task, then start it on an
        // uncancelled worker.
        startWorkerIfNeeded()
    }
}
