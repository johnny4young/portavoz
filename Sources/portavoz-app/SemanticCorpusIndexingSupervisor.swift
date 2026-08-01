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
    private let maintenanceState: SemanticCorpusMaintenanceState
    private let drain: Drain
    private var drainTask: Task<Void, Never>?
    private var rerunRequested = false

    init(
        isEnabled: Bool = true,
        maintenanceState: SemanticCorpusMaintenanceState = .init(),
        drain: @escaping Drain
    ) {
        self.isEnabled = isEnabled
        self.maintenanceState = maintenanceState
        self.drain = drain
    }

    func kick() {
        guard isEnabled else { return }
        guard drainTask == nil else {
            rerunRequested = true
            return
        }

        rerunRequested = false
        maintenanceState.transition(to: .building)
        let drain = drain
        drainTask = Task { @MainActor [weak self] in
            let terminalPhase: SemanticCorpusMaintenancePhase
            do {
                _ = try await drain()
                terminalPhase = .idle
            } catch is CancellationError {
                terminalPhase = .idle
            } catch {
                terminalPhase = .failed
                Self.logger.error(
                    "Semantic indexing maintenance failed; durable rows remain pending")
            }
            self?.finishedDrain(terminalPhase: terminalPhase)
        }
    }

    private func finishedDrain(
        terminalPhase: SemanticCorpusMaintenancePhase
    ) {
        drainTask = nil
        guard rerunRequested else {
            maintenanceState.transition(to: terminalPhase)
            return
        }
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
        guard try await store.hasSemanticCorpusRows() else { return .empty }
        guard await runtime.hasAvailableAssets else { return .empty }
        guard let profile = await runtime.semanticEmbeddingProfile(),
              profile.isValid,
              try await store.semanticIndexRequiresMaintenance(for: profile)
        else { return .empty }
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
