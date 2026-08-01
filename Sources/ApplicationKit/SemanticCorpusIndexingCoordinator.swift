import Foundation

/// Process-shared ownership for semantic corpus backfill.
///
/// Library search may request one opportunistic batch while background
/// maintenance or explicit benchmark preparation requests a complete drain.
/// Only one backfill flight can execute at a time: redundant Library requests
/// are coalesced, while a complete drain waits behind an already-running
/// bounded batch and then continues from durable missing rows.
public actor SemanticCorpusIndexingCoordinator {
    private enum Demand: Sendable {
        case bounded(limit: Int)
        case complete(batchSize: Int)

        var isComplete: Bool {
            if case .complete = self { return true }
            return false
        }
    }

    private struct Flight {
        let id: UUID
        let demand: Demand
        let task: Task<SemanticCorpusIndexingResult, Error>
        var waiters: Set<UUID>
    }

    private let operation: IndexSemanticCorpus
    private var active: Flight?
    private var completeDemandCount = 0

    public init(operation: IndexSemanticCorpus) {
        self.operation = operation
    }

    /// Advances at most one batch. If any backfill is already active, the
    /// request is represented by that durable work and no second flight is
    /// queued. Exact FTS and already-indexed semantic rows remain available.
    public func nextBatch(
        using embedder: any SemanticTextEmbedding,
        limit: Int = 512
    ) async throws -> SemanticCorpusIndexingResult {
        guard limit > 0 else {
            throw SemanticCorpusIndexingError.invalidBatchSize
        }
        guard active == nil, completeDemandCount == 0 else {
            return .empty
        }
        return try await startAndAwait(
            demand: .bounded(limit: limit),
            using: embedder)
    }

    /// Drains every currently missing row. A complete caller joins an active
    /// flight instead of duplicating it, then continues until the corpus is
    /// complete. While this demand exists, new bounded requests coalesce.
    public func all(
        using embedder: any SemanticTextEmbedding,
        batchSize: Int = 256
    ) async throws -> SemanticCorpusIndexingResult {
        guard batchSize > 0 else {
            throw SemanticCorpusIndexingError.invalidBatchSize
        }

        completeDemandCount += 1
        defer { completeDemandCount -= 1 }

        var result = SemanticCorpusIndexingResult.empty
        while let flight = active {
            result += try await awaitFlight(flight)
            try Task.checkCancellation()
            if flight.demand.isComplete {
                return result
            }
        }

        result += try await startAndAwait(
            demand: .complete(batchSize: batchSize),
            using: embedder)
        return result
    }

    private func startAndAwait(
        demand: Demand,
        using embedder: any SemanticTextEmbedding
    ) async throws -> SemanticCorpusIndexingResult {
        let operation = operation
        let task = Task(priority: .utility) {
            switch demand {
            case .bounded(let limit):
                try await operation.nextBatch(
                    using: embedder,
                    limit: limit)
            case .complete(let batchSize):
                try await operation.all(
                    using: embedder,
                    batchSize: batchSize)
            }
        }
        let flight = Flight(
            id: UUID(),
            demand: demand,
            task: task,
            waiters: [])
        active = flight
        return try await awaitFlight(flight)
    }

    private func awaitFlight(
        _ flight: Flight
    ) async throws -> SemanticCorpusIndexingResult {
        let waiterID = UUID()
        guard active?.id == flight.id else { return .empty }
        active?.waiters.insert(waiterID)

        do {
            let result = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        flightID: flight.id)
                }
            }
            completeWaiter(waiterID, flightID: flight.id)
            try Task.checkCancellation()
            return result
        } catch {
            completeWaiter(waiterID, flightID: flight.id)
            throw error
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        flightID: UUID
    ) {
        guard var flight = active, flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        active = flight
        if flight.waiters.isEmpty {
            flight.task.cancel()
        }
    }

    private func completeWaiter(
        _ waiterID: UUID,
        flightID: UUID
    ) {
        guard var flight = active, flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        active = nil
    }
}
