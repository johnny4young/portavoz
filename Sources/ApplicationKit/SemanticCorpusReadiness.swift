import Foundation
import StorageKit

/// One capability-neutral view of semantic search readiness.
///
/// Exact search remains available in every state. Published semantic vectors
/// can still augment results while maintenance is partial, active, or failed;
/// unsupported means this process cannot create a query vector.
public enum SemanticCorpusReadiness: String, CaseIterable, Equatable, Sendable {
    case ready
    case partial
    case building
    case unsupported
    case failed

    public var canSearchPublishedVectors: Bool {
        self != .unsupported
    }
}

public enum SemanticCorpusMaintenancePhase: Equatable, Sendable {
    case idle
    case building
    case failed
}

/// Process-shared, payload-free maintenance state. Durable pending rows remain
/// the corpus cursor; this value only distinguishes active and failed work.
public final class SemanticCorpusMaintenanceState: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: SemanticCorpusMaintenancePhase

    public init(
        phase: SemanticCorpusMaintenancePhase = .idle
    ) {
        self.phase = phase
    }

    public var current: SemanticCorpusMaintenancePhase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    public func transition(
        to phase: SemanticCorpusMaintenancePhase
    ) {
        lock.lock()
        self.phase = phase
        lock.unlock()
    }
}

/// Resolves readiness from installed capability, durable corpus progress, and
/// the process maintenance phase without preparing a model or writing rows.
public struct ResolveSemanticCorpusReadiness: Sendable {
    private let store: MeetingStore
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let maintenanceState: SemanticCorpusMaintenanceState

    public init(
        store: MeetingStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        maintenanceState: SemanticCorpusMaintenanceState = .init()
    ) {
        self.store = store
        self.runtime = runtime
        self.maintenanceState = maintenanceState
    }

    public func current() async throws -> SemanticCorpusReadiness {
        try Task.checkCancellation()
        guard await runtime.hasAvailableAssets else { return .unsupported }
        try Task.checkCancellation()
        guard let profile = await runtime.semanticEmbeddingProfile(),
              profile.isValid
        else { return .unsupported }

        let hasPendingRows: Bool
        do {
            hasPendingRows = try await store.semanticIndexRequiresMaintenance(
                for: profile)
        } catch {
            try Task.checkCancellation()
            return .failed
        }
        guard hasPendingRows else { return .ready }

        switch maintenanceState.current {
        case .idle:
            return .partial
        case .building:
            return .building
        case .failed:
            return .failed
        }
    }
}
