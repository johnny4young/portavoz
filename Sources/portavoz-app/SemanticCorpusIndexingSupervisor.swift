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
    typealias Drain = @Sendable (_ owner: String) async throws
        -> SemanticCorpusMaintenanceRun

    private static let logger = Logger(
        subsystem: "app.portavoz.mac",
        category: "semantic-indexing")

    private let isEnabled: Bool
    private let maintenanceState: SemanticCorpusMaintenanceState
    private let drain: Drain
    private let owner = "semantic-maintenance-\(UUID().uuidString.lowercased())"
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
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
        wakeTask?.cancel()
        wakeTask = nil
        guard drainTask == nil else {
            rerunRequested = true
            return
        }

        rerunRequested = false
        maintenanceState.transition(to: .building)
        let drain = drain
        let owner = owner
        drainTask = Task { @MainActor [weak self] in
            let run: SemanticCorpusMaintenanceRun
            do {
                run = try await drain(owner)
            } catch is CancellationError {
                run = .empty
            } catch {
                run = SemanticCorpusMaintenanceRun(terminalFailure: true)
                Self.logger.error(
                    "Semantic maintenance coordination failed; durable work remains replayable")
            }
            self?.finishedDrain(run)
        }
    }

    private func finishedDrain(_ run: SemanticCorpusMaintenanceRun) {
        drainTask = nil
        if rerunRequested || run.shouldRerun {
            rerunRequested = false
            kick()
            return
        }
        maintenanceState.transition(to: run.terminalFailure ? .failed : .idle)
        if let retryAt = run.retryAt {
            scheduleWake(at: retryAt)
        }
    }

    private func scheduleWake(at date: Date) {
        let delay = max(0, date.timeIntervalSinceNow)
        wakeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.kick()
        }
    }
}

/// Production adapter for the background owner. It checks cheap durable state
/// before borrowing the semantic runtime and never downloads OS assets.
struct AppSemanticCorpusBackgroundIndexer: Sendable {
    let store: MeetingStore
    let runtime: any SemanticEmbeddingRuntimeClient
    let coordinator: SemanticCorpusIndexingCoordinator
    let captureState: AppResourceCaptureState

    func drain(
        owner: String = "semantic-maintenance-test-owner"
    ) async throws -> SemanticCorpusMaintenanceRun {
        try await ProcessSemanticCorpusMaintenance(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            mayStart: { captureState.current == .inactive }
        ).execute(owner: owner)
    }
}
