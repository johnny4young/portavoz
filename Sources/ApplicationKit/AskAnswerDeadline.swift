import Foundation

/// Value-scoped clock injection keeps deadline tests independent of executor
/// scheduling without changing the public use-case initializers.
struct AskAnswerClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = Self(
        now: { ContinuousClock.now },
        sleepUntil: { try await ContinuousClock().sleep(until: $0) })
}

/// The budget starts once, before either task-group child is scheduled. Every
/// publication boundary checks this same instant; the timer is only a wake-up.
struct AskAnswerDeadline: Sendable {
    let clock: AskAnswerClock
    let instant: ContinuousClock.Instant

    init(after duration: Duration, clock: AskAnswerClock = .continuous) {
        self.clock = clock
        instant = clock.now().advanced(by: duration)
    }

    var isExpired: Bool { clock.now() >= instant }

    func check() throws {
        try Task.checkCancellation()
        if isExpired { throw AskTimeoutError() }
    }
}

struct AskTimeoutError: Error {}

private enum AskTimedOperationResult<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)
    case timedOut
}

func withAskTimeout<Value: Sendable>(
    _ deadline: AskAnswerDeadline,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    do {
        let value = try await raceAskDeadline(
            deadline, onTimeout: onTimeout, operation: operation)
        // Structured teardown can suspend after the operation won. Fence both
        // its value and its thrown error against caller cancellation.
        if deadline.isExpired {
            await onTimeout()
            throw AskTimeoutError()
        }
        try Task.checkCancellation()
        return value
    } catch {
        try Task.checkCancellation()
        throw error
    }
}

private func raceAskDeadline<Value: Sendable>(
    _ deadline: AskAnswerDeadline,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(
        of: AskTimedOperationResult<Value>.self
    ) { group in
        group.addTask {
            do {
                try deadline.check()
                let value = try await operation()
                try Task.checkCancellation()
                return deadline.isExpired ? .timedOut : .value(value)
            } catch {
                try Task.checkCancellation()
                if deadline.isExpired { return .timedOut }
                return .failure(error)
            }
        }
        group.addTask {
            try await deadline.clock.sleepUntil(deadline.instant)
            return .timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        if !deadline.isExpired {
            switch first {
            case .value(let value): return value
            case .failure(let error): throw error
            case .timedOut: break
            }
        }
        // Close publication before cancelling the provider. Deadline admission
        // also protects callbacks when this parent or timer has not run yet.
        await onTimeout()
        try Task.checkCancellation()
        throw AskTimeoutError()
    }
}
