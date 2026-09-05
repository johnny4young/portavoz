import Foundation
import GRDB

extension MeetingStore {
    func observedStream<Reducer>(
        _ observation: ValueObservation<Reducer>
    ) -> AsyncThrowingStream<Reducer.Value, Error>
    where Reducer: ValueReducer, Reducer.Value: Sendable {
        let values = observation.values(
            in: database,
            bufferingPolicy: .bufferingNewest(1))
        let iterator = ObservedStreamIterator(values.makeAsyncIterator())
        return AsyncThrowingStream(unfolding: {
            try await iterator.next()
        })
    }
}

/// Pulls directly from GRDB so its cancellable has the consumer iterator's
/// lifetime. There is no forwarding task or continuation teardown cycle.
private final class ObservedStreamIterator<Iterator>: @unchecked Sendable
where Iterator: AsyncIteratorProtocol & GRDBSendableMetatype {
    private let lock = NSLock()
    private var iterator: Iterator?

    init(_ iterator: Iterator) {
        self.iterator = iterator
    }

    func next() async throws -> Iterator.Element? {
        guard var iterator = takeIterator() else {
            throw ObservedStreamIteratorError.concurrentNext
        }
        do {
            let value = try await iterator.next()
            restore(iterator)
            return value
        } catch {
            restore(iterator)
            throw error
        }
    }

    private func takeIterator() -> Iterator? {
        lock.withLock {
            let iterator = self.iterator
            self.iterator = nil
            return iterator
        }
    }

    private func restore(_ iterator: Iterator) {
        lock.withLock { self.iterator = iterator }
    }
}

private enum ObservedStreamIteratorError: Error {
    case concurrentNext
}
