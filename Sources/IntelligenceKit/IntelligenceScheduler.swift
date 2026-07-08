import Foundation

/// Serializes every on-device language-model call of the process behind a
/// single-flight priority queue.
///
/// The 3B Foundation Model is ONE shared resource: rolling summaries, the
/// live companion (D26), naming, RAG answers and refine re-summaries all want
/// it, and the ANE serializes generation anyway — issuing concurrent
/// requests just buries the queueing inside the FM daemon where it can't be
/// managed. Scheduling at the granularity of ONE model call keeps any queue
/// wait bounded by the single call in flight (~1–4 s), which is what makes
/// an interactive budget like the companion's < 5 s attainable while a
/// background map-reduce chain runs: chains release the slot BETWEEN calls,
/// so interactive work interleaves into the gaps.
///
/// The scheduler knows nothing about FoundationModels — it queues opaque
/// async operations — so it unit-tests on any platform.
public actor IntelligenceScheduler {
    public enum Priority: Int, Comparable, Sendable {
        /// Rolling-summary notes, refine re-summaries, embedding backfill.
        case background = 0
        /// Companion question-detection ticks: frequent, cheap, droppable.
        case live = 1
        /// A human is waiting: companion answers, naming, `ask`.
        case interactive = 2

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Process-wide instance: providers are cheap structs created ad hoc,
    /// so serialization must live somewhere shared.
    public static let shared = IntelligenceScheduler()

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let sequence: UInt64
        let key: String?
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private var isRunning = false
    private var sequence: UInt64 = 0
    /// Cancellations that arrived before their waiter was enqueued (the
    /// task-cancellation handler can fire first) — consumed on enqueue.
    private var earlyCancellations: Set<UUID> = []

    public init() {}

    /// Runs `operation` — ONE model call, by convention — when the slot
    /// frees up, ordered by priority then FIFO. Jobs sharing a `key` are
    /// latest-wins: scheduling a new one cancels a still-QUEUED older one
    /// with `CancellationError` (an in-flight call is never interrupted).
    /// Task cancellation while queued dequeues and throws.
    public func run<T: Sendable>(
        _ priority: Priority,
        key: String? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority: priority, key: key)
        defer { releaseAndResumeNext() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Queued + running work, for tests and diagnostics.
    public var pendingCount: Int { waiters.count + (isRunning ? 1 : 0) }

    // MARK: - Internals

    private func acquire(priority: Priority, key: String?) async throws {
        if !isRunning, waiters.isEmpty {
            isRunning = true
            return
        }

        if let key, let index = waiters.firstIndex(where: { $0.key == key }) {
            let replaced = waiters.remove(at: index)
            replaced.continuation.resume(throwing: CancellationError())
        }

        let id = UUID()
        sequence += 1
        let ticket = sequence
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if earlyCancellations.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    Waiter(
                        id: id, priority: priority, sequence: ticket,
                        key: key, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            earlyCancellations.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseAndResumeNext() {
        guard let index = nextWaiterIndex() else {
            isRunning = false
            return
        }
        let next = waiters.remove(at: index)
        next.continuation.resume()  // the slot stays taken
    }

    /// Highest priority wins; FIFO (lowest sequence) within a priority.
    private func nextWaiterIndex() -> Int? {
        waiters.indices.max { lhs, rhs in
            let (a, b) = (waiters[lhs], waiters[rhs])
            if a.priority != b.priority { return a.priority < b.priority }
            return a.sequence > b.sequence
        }
    }
}
