import Foundation

/// Deterministic test seam for production tasks that wait before publishing.
/// Tests observe suspension, then resume or cancel the exact call without
/// assuming anything about host scheduling speed.
actor ControlledTestSleep {
    /// Bounds only a broken test; waiters wake on the event itself.
    static let hangGuard: Duration = .seconds(30)

    private var durations: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancellationCount = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait(for duration: Duration) async throws {
        let callIndex = durations.count
        durations.append(duration)

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[callIndex] = continuation
                wakeWaiters()
            }
        } onCancel: {
            Task { await self.cancelCall(at: callIndex) }
        }
    }

    func waitUntilCallCount(_ expected: Int) async -> Bool {
        await waitUntil { durations.count >= expected }
    }

    func waitUntilCancellationCount(_ expected: Int) async -> Bool {
        await waitUntil { cancellationCount >= expected }
    }

    func requestedDuration(at callIndex: Int) -> Duration? {
        durations.indices.contains(callIndex) ? durations[callIndex] : nil
    }

    func resumeCall(at callIndex: Int) -> Bool {
        guard let continuation = continuations.removeValue(forKey: callIndex) else {
            return false
        }
        continuation.resume()
        return true
    }

    private func cancelCall(at callIndex: Int) {
        guard let continuation = continuations.removeValue(forKey: callIndex) else {
            return
        }
        cancellationCount += 1
        continuation.resume(throwing: CancellationError())
        wakeWaiters()
    }

    // Suspends instead of polling, so a slow caller cannot exhaust a budget
    // and the waiter never competes with the call it is waiting for.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        while !condition() {
            let id = UUID()
            let timeout = Task {
                guard (try? await Task.sleep(for: Self.hangGuard)) != nil else { return }
                expireWaiter(id)
            }
            let woken = await withCheckedContinuation { waiters[id] = $0 }
            timeout.cancel()
            if !woken { return condition() }
        }
        return true
    }

    private func wakeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume(returning: true) }
    }

    private func expireWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
}
