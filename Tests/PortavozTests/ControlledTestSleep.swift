import Foundation

/// Deterministic test seam for production tasks that wait before publishing.
/// Tests observe suspension, then resume or cancel the exact call without
/// assuming anything about host scheduling speed.
actor ControlledTestSleep {
    private var durations: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancellationCount = 0

    func wait(for duration: Duration) async throws {
        let callIndex = durations.count
        durations.append(duration)

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[callIndex] = continuation
            }
        } onCancel: {
            Task { await self.cancelCall(at: callIndex) }
        }
    }

    func waitUntilCallCount(_ expected: Int) async -> Bool {
        for _ in 0..<20_000 {
            if durations.count >= expected { return true }
            await Task.yield()
        }
        return false
    }

    func waitUntilCancellationCount(_ expected: Int) async -> Bool {
        for _ in 0..<20_000 {
            if cancellationCount >= expected { return true }
            await Task.yield()
        }
        return false
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
    }
}
