import Foundation
import PortavozCore
import StorageKit

public protocol SemanticCorpusMaintenanceStore: Sendable {
    func hasSemanticCorpusRows() async throws -> Bool

    func semanticIndexRequiresMaintenance(
        for profile: SemanticEmbeddingProfile
    ) async throws -> Bool

    func admitSemanticCorpusMaintenance(
        targetFingerprint: String,
        maxAttempts: Int,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func claimSemanticCorpusMaintenance(
        targetFingerprint: String,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob?

    func heartbeatSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws

    func suspendSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func completeSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func failSemanticCorpusMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        errorCode: String,
        retryAt: Date,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func recoverExpiredSemanticCorpusMaintenance(
        at timestamp: Date
    ) async throws -> Int

    func nextScheduledSemanticCorpusMaintenanceDate(
        after timestamp: Date
    ) async throws -> Date?

    func hasDueSemanticCorpusMaintenance(
        targetFingerprint: String,
        at timestamp: Date
    ) async throws -> Bool
}

extension MeetingStore: SemanticCorpusMaintenanceStore {}

public struct SemanticCorpusMaintenanceRun: Equatable, Sendable {
    public let indexing: SemanticCorpusIndexingResult
    public let shouldRerun: Bool
    public let retryAt: Date?
    public let terminalFailure: Bool

    public init(
        indexing: SemanticCorpusIndexingResult = .empty,
        shouldRerun: Bool = false,
        retryAt: Date? = nil,
        terminalFailure: Bool = false
    ) {
        self.indexing = indexing
        self.shouldRerun = shouldRerun
        self.retryAt = retryAt
        self.terminalFailure = terminalFailure
    }

    public static let empty = SemanticCorpusMaintenanceRun()
    public static let paused = SemanticCorpusMaintenanceRun(indexing: .paused)
}

/// Claims and settles one content-free semantic maintenance operation while
/// the vector rows themselves remain the exact replay cursor.
public struct ProcessSemanticCorpusMaintenance: Sendable {
    private static let failureCode = "maintenance.semantic.failed"

    private let store: any SemanticCorpusMaintenanceStore
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let coordinator: SemanticCorpusIndexingCoordinator
    private let mayStart: @Sendable () -> Bool
    private let leaseDuration: TimeInterval
    private let heartbeatInterval: Duration
    private let retryDelays: [TimeInterval]
    private let now: @Sendable () -> Date

    public init(
        store: any SemanticCorpusMaintenanceStore,
        runtime: any SemanticEmbeddingRuntimeClient,
        coordinator: SemanticCorpusIndexingCoordinator,
        mayStart: @escaping @Sendable () -> Bool = { true },
        leaseDuration: TimeInterval = 120,
        heartbeatInterval: Duration = .seconds(30),
        retryDelays: [TimeInterval] = [5, 30],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.runtime = runtime
        self.coordinator = coordinator
        self.mayStart = mayStart
        self.leaseDuration = leaseDuration
        self.heartbeatInterval = heartbeatInterval
        self.retryDelays = retryDelays
        self.now = now
    }

    public func execute(owner: String) async throws -> SemanticCorpusMaintenanceRun {
        try Task.checkCancellation()
        guard mayStart() else { return .paused }
        guard try await store.hasSemanticCorpusRows() else { return .empty }
        guard await runtime.hasAvailableAssets,
              let profile = await runtime.semanticEmbeddingProfile(),
              profile.isValid
        else { return .empty }

        let timestamp = now()
        _ = try await store.recoverExpiredSemanticCorpusMaintenance(at: timestamp)
        let admitted = try await store.admitSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            maxAttempts: retryDelays.count + 1,
            at: timestamp)
        guard admitted.state != .failed else {
            return SemanticCorpusMaintenanceRun(terminalFailure: true)
        }
        guard mayStart() else { return .paused }
        guard let job = try await store.claimSemanticCorpusMaintenance(
            targetFingerprint: profile.fingerprint,
            owner: owner,
            leaseDuration: leaseDuration,
            at: now())
        else {
            return SemanticCorpusMaintenanceRun(
                retryAt: try await store.nextScheduledSemanticCorpusMaintenanceDate(
                    after: now()))
        }

        return try await processClaimedJob(job, profile: profile, owner: owner)
    }

    private func processClaimedJob(
        _ job: DerivedMaintenanceJob,
        profile: SemanticEmbeddingProfile,
        owner: String
    ) async throws -> SemanticCorpusMaintenanceRun {
        let heartbeat = heartbeatTask(for: job, owner: owner)
        defer { heartbeat.cancel() }
        do {
            let indexing = try await runtime.withPreparedEmbedding(
                allowAssetDownload: false
            ) { [coordinator] embedder in
                let preparedProfile = await embedder.semanticEmbeddingProfile()
                guard preparedProfile.fingerprint == job.targetFingerprint else {
                    throw SemanticCorpusMaintenanceError.profileChanged
                }
                return try await coordinator.all(
                    using: embedder,
                    batchSize: 256)
            }
            if indexing.pausedByPolicy || !mayStart() {
                _ = try await store.suspendSemanticCorpusMaintenance(
                    job.id, owner: owner, at: now())
                return SemanticCorpusMaintenanceRun(indexing: indexing)
            }

            _ = try await store.completeSemanticCorpusMaintenance(
                job.id, owner: owner, at: now())
            let current = try await store.admitSemanticCorpusMaintenance(
                targetFingerprint: profile.fingerprint,
                maxAttempts: retryDelays.count + 1,
                at: now())
            let requiresMaintenance = try await store.semanticIndexRequiresMaintenance(
                for: profile)
            let due = try await store.hasDueSemanticCorpusMaintenance(
                targetFingerprint: profile.fingerprint,
                at: now())
            return SemanticCorpusMaintenanceRun(
                indexing: indexing,
                shouldRerun: current.id != job.id || requiresMaintenance || due,
                retryAt: try await store.nextScheduledSemanticCorpusMaintenanceDate(
                    after: now()))
        } catch is CancellationError {
            _ = try? await store.suspendSemanticCorpusMaintenance(
                job.id, owner: owner, at: now())
            throw CancellationError()
        } catch SemanticCorpusMaintenanceError.profileChanged {
            _ = try await store.suspendSemanticCorpusMaintenance(
                job.id, owner: owner, at: now())
            return SemanticCorpusMaintenanceRun(shouldRerun: true)
        } catch {
            let attemptedRetry = max(0, job.attempt - 1)
            let delay = retryDelays.indices.contains(attemptedRetry)
                ? retryDelays[attemptedRetry]
                : retryDelays.last ?? 0
            let failed = try await store.failSemanticCorpusMaintenance(
                job.id,
                owner: owner,
                errorCode: Self.failureCode,
                retryAt: now().addingTimeInterval(delay),
                at: now())
            return SemanticCorpusMaintenanceRun(
                retryAt: failed.notBefore,
                terminalFailure: failed.state == .failed)
        }
    }

    private func heartbeatTask(
        for job: DerivedMaintenanceJob,
        owner: String
    ) -> Task<Void, Never> {
        let store = store
        let interval = heartbeatInterval
        let leaseDuration = leaseDuration
        let now = now
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try await store.heartbeatSemanticCorpusMaintenance(
                        job.id,
                        owner: owner,
                        leaseDuration: leaseDuration,
                        at: now())
                } catch {
                    return
                }
            }
        }
    }
}

private enum SemanticCorpusMaintenanceError: Error {
    case profileChanged
}
