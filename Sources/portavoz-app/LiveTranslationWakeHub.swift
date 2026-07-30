import Foundation

struct LiveTranslationWakeSubscription: Sendable {
    let stream: AsyncStream<Void>
    private let cancellation: @Sendable () -> Void

    init(
        stream: AsyncStream<Void>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        self.stream = stream
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

/// Broadcasts caption and consent changes to the currently active Translation
/// framework lane. Each subscriber retains one wake at most: a burst means
/// "recompute from the newest controller state", never one unit of queued work
/// per caption. Durable source captions stay outside this optional signal path.
final class LiveTranslationWakeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations:
        [UUID: AsyncStream<Void>.Continuation] = [:]

    var subscriberCount: Int {
        lock.withLock { continuations.count }
    }

    func subscribe() -> LiveTranslationWakeSubscription {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id: id)
        }
        lock.withLock {
            continuations[id] = pair.continuation
        }
        return LiveTranslationWakeSubscription(
            stream: pair.stream,
            cancellation: { [weak self] in
                self?.finish(id: id)
            })
    }

    func signal() {
        let current = lock.withLock {
            Array(continuations.values)
        }
        for continuation in current {
            continuation.yield()
        }
    }

    private func finish(id: UUID) {
        let continuation = lock.withLock {
            continuations.removeValue(forKey: id)
        }
        continuation?.finish()
    }

    private func remove(id: UUID) {
        lock.withLock {
            continuations[id] = nil
        }
    }
}
