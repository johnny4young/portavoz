import Foundation
import PortavozCore
import StorageKit

public protocol MeetingMemoryGraphMaintenanceStore: Sendable {
    func meetingMemoryGraphRequiresMaintenance(
        targetFingerprint: String
    ) async throws -> Bool

    func admitMeetingMemoryGraphMaintenance(
        targetFingerprint: String,
        maxAttempts: Int,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func claimMeetingMemoryGraphMaintenance(
        targetFingerprint: String,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob?

    func heartbeatMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        leaseDuration: TimeInterval,
        at timestamp: Date
    ) async throws

    func suspendMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func completeMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func failMeetingMemoryGraphMaintenance(
        _ id: DerivedMaintenanceJobID,
        owner: String,
        errorCode: String,
        retryAt: Date,
        at timestamp: Date
    ) async throws -> DerivedMaintenanceJob

    func recoverExpiredMeetingMemoryGraphMaintenance(
        at timestamp: Date
    ) async throws -> Int

    func nextScheduledMeetingMemoryGraphMaintenanceDate(
        after timestamp: Date
    ) async throws -> Date?

    func hasDueMeetingMemoryGraphMaintenance(
        targetFingerprint: String,
        at timestamp: Date
    ) async throws -> Bool
}

extension MeetingStore: MeetingMemoryGraphMaintenanceStore {}

public struct MeetingMemoryGraphMaintenanceRun: Equatable, Sendable {
    public let projection: MeetingMemoryGraphProjectionResult
    public let shouldRerun: Bool
    public let retryAt: Date?
    public let terminalFailure: Bool

    public init(
        projection: MeetingMemoryGraphProjectionResult = .empty,
        shouldRerun: Bool = false,
        retryAt: Date? = nil,
        terminalFailure: Bool = false
    ) {
        self.projection = projection
        self.shouldRerun = shouldRerun
        self.retryAt = retryAt
        self.terminalFailure = terminalFailure
    }

    public static let empty = MeetingMemoryGraphMaintenanceRun()
    public static let paused = MeetingMemoryGraphMaintenanceRun(projection: .paused)
}

public struct ProcessMeetingMemoryGraphMaintenance: Sendable {
    private static let failureCode = "maintenance.memory-graph.failed"

    private let store: any MeetingMemoryGraphMaintenanceStore
    private let projector: ProjectMeetingMemoryGraph
    private let mayStart: @Sendable () -> Bool
    private let leaseDuration: TimeInterval
    private let heartbeatInterval: Duration
    private let retryDelays: [TimeInterval]
    private let now: @Sendable () -> Date

    public init(
        store: any MeetingMemoryGraphMaintenanceStore,
        projector: ProjectMeetingMemoryGraph,
        mayStart: @escaping @Sendable () -> Bool = { true },
        leaseDuration: TimeInterval = 120,
        heartbeatInterval: Duration = .seconds(30),
        retryDelays: [TimeInterval] = [5, 30],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.projector = projector
        self.mayStart = mayStart
        self.leaseDuration = leaseDuration
        self.heartbeatInterval = heartbeatInterval
        self.retryDelays = retryDelays
        self.now = now
    }

    public func execute(owner: String) async throws -> MeetingMemoryGraphMaintenanceRun {
        try Task.checkCancellation()
        guard mayStart() else { return .paused }
        let fingerprint = MeetingMemoryGraphProjectionProfile.fingerprint
        let timestamp = now()
        _ = try await store.recoverExpiredMeetingMemoryGraphMaintenance(at: timestamp)
        guard try await store.meetingMemoryGraphRequiresMaintenance(
            targetFingerprint: fingerprint)
        else { return .empty }
        let admitted = try await store.admitMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint,
            maxAttempts: retryDelays.count + 1,
            at: timestamp)
        guard admitted.state != .failed else {
            return MeetingMemoryGraphMaintenanceRun(terminalFailure: true)
        }
        guard mayStart() else { return .paused }
        guard let job = try await store.claimMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint,
            owner: owner,
            leaseDuration: leaseDuration,
            at: now())
        else {
            return MeetingMemoryGraphMaintenanceRun(
                retryAt: try await store.nextScheduledMeetingMemoryGraphMaintenanceDate(
                    after: now()))
        }
        return try await processClaimedJob(job, owner: owner)
    }

    private func processClaimedJob(
        _ job: DerivedMaintenanceJob,
        owner: String
    ) async throws -> MeetingMemoryGraphMaintenanceRun {
        let heartbeat = heartbeatTask(for: job, owner: owner)
        defer { heartbeat.cancel() }
        do {
            let projection = try await projector.all(
                job: job,
                owner: owner)
            if projection.pausedByPolicy || !mayStart() {
                _ = try await store.suspendMeetingMemoryGraphMaintenance(
                    job.id, owner: owner, at: now())
                return MeetingMemoryGraphMaintenanceRun(projection: projection)
            }
            _ = try await store.completeMeetingMemoryGraphMaintenance(
                job.id, owner: owner, at: now())
            let current = try await store.admitMeetingMemoryGraphMaintenance(
                targetFingerprint: job.targetFingerprint,
                maxAttempts: retryDelays.count + 1,
                at: now())
            let requiresMaintenance = try await store.meetingMemoryGraphRequiresMaintenance(
                targetFingerprint: job.targetFingerprint)
            let due = try await store.hasDueMeetingMemoryGraphMaintenance(
                targetFingerprint: job.targetFingerprint,
                at: now())
            return MeetingMemoryGraphMaintenanceRun(
                projection: projection,
                shouldRerun: current.id != job.id || requiresMaintenance || due,
                retryAt: try await store.nextScheduledMeetingMemoryGraphMaintenanceDate(
                    after: now()))
        } catch is CancellationError {
            _ = try? await store.suspendMeetingMemoryGraphMaintenance(
                job.id, owner: owner, at: now())
            throw CancellationError()
        } catch {
            let attemptedRetry = max(0, job.attempt - 1)
            let delay = retryDelays.indices.contains(attemptedRetry)
                ? retryDelays[attemptedRetry]
                : retryDelays.last ?? 0
            let failed = try await store.failMeetingMemoryGraphMaintenance(
                job.id,
                owner: owner,
                errorCode: Self.failureCode,
                retryAt: now().addingTimeInterval(delay),
                at: now())
            return MeetingMemoryGraphMaintenanceRun(
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
                    try await store.heartbeatMeetingMemoryGraphMaintenance(
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
