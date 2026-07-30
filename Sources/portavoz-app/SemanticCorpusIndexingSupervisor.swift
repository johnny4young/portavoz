import ApplicationKit
import Foundation
import OSLog
import PortavozCore
import StorageKit

/// Process-owned, signal-driven semantic maintenance.
///
/// Searchable mutations and capture completion may kick repeatedly. One drain
/// runs at a time, bursts collapse to one rerun, and no timer polls SQLite.
@MainActor
final class SemanticCorpusIndexingSupervisor {
    typealias Drain = @Sendable () async throws
        -> SemanticCorpusIndexingResult

    private static let logger = Logger(
        subsystem: "app.portavoz.mac",
        category: "semantic-indexing")

    private let isEnabled: Bool
    private let drain: Drain
    private var drainTask: Task<Void, Never>?
    private var rerunRequested = false

    init(
        isEnabled: Bool = true,
        drain: @escaping Drain
    ) {
        self.isEnabled = isEnabled
        self.drain = drain
    }

    func kick() {
        guard isEnabled else { return }
        guard drainTask == nil else {
            rerunRequested = true
            return
        }

        rerunRequested = false
        let drain = drain
        drainTask = Task { @MainActor [weak self] in
            defer { self?.finishedDrain() }
            do {
                _ = try await drain()
            } catch is CancellationError {
            } catch {
                Self.logger.error(
                    "Semantic indexing maintenance failed; durable rows remain pending")
            }
        }
    }

    private func finishedDrain() {
        drainTask = nil
        guard rerunRequested else { return }
        rerunRequested = false
        kick()
    }
}

/// Production adapter for the background owner. It checks cheap durable state
/// before borrowing the semantic runtime and never downloads OS assets.
struct AppSemanticCorpusBackgroundIndexer: Sendable {
    let store: MeetingStore
    let runtime: any SemanticEmbeddingRuntimeClient
    let coordinator: SemanticCorpusIndexingCoordinator
    let captureState: AppResourceCaptureState

    func drain() async throws -> SemanticCorpusIndexingResult {
        try Task.checkCancellation()
        guard captureState.current == .inactive else { return .paused }
        guard !(
            try await store.segmentsNeedingEmbeddings(limit: 1)
        ).isEmpty else { return .empty }
        guard await runtime.hasAvailableAssets else { return .empty }
        try Task.checkCancellation()
        guard captureState.current == .inactive else { return .paused }

        return try await runtime.withPreparedEmbedding(
            allowAssetDownload: false
        ) { [coordinator] embedder in
            try await coordinator.all(
                using: embedder,
                batchSize: 256)
        }
    }
}
