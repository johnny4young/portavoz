import Foundation
import PortavozCore
import StorageKit

/// Rebuilds the disposable typed graph projection from authoritative local
/// records. Durable invalidation rows are the cursor; policy may pause only
/// between committed batches.
public struct ProjectMeetingMemoryGraph: Sendable {
    private static let workload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .memoryGraph,
        operation: .execute)

    private let store: MeetingStore
    private let telemetry: ResourceWorkloadTelemetry
    private let maintenanceGate: DurableMaintenanceGate
    private let now: @Sendable () -> Date

    public init(
        store: MeetingStore,
        telemetry: ResourceWorkloadTelemetry = .disabled,
        maintenanceGate: DurableMaintenanceGate = .unrestricted,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.telemetry = telemetry
        self.maintenanceGate = maintenanceGate
        self.now = now
    }

    public func all(
        job: DerivedMaintenanceJob,
        owner: String,
        batchSize: Int = 128
    ) async throws -> MeetingMemoryGraphProjectionResult {
        guard job.kind == .meetingMemoryGraph,
              job.sourceGeneration >= 0,
              batchSize > 0
        else {
            throw MeetingMemoryGraphProjectionError.invalidBatch
        }
        try Task.checkCancellation()
        guard shouldProceed(at: .admission) else { return .paused }
        return try await telemetry.measure(Self.workload) {
            var result = MeetingMemoryGraphProjectionResult.empty
            while true {
                try Task.checkCancellation()
                let batch = try await store.projectMeetingMemoryGraphBatch(
                    jobID: job.id,
                    owner: owner,
                    targetFingerprint: job.targetFingerprint,
                    through: job.sourceGeneration,
                    limit: batchSize,
                    at: now())
                result += batch
                guard batch.rebuiltScopes == batchSize else { return result }
                guard shouldProceed(at: .checkpoint) else {
                    return MeetingMemoryGraphProjectionResult(
                        rebuiltScopes: result.rebuiltScopes,
                        publishedEdges: result.publishedEdges,
                        resetProjection: result.resetProjection,
                        pausedByPolicy: true)
                }
            }
        }
    }

    private func shouldProceed(
        at phase: ResourceGovernorEvaluationPhase
    ) -> Bool {
        maintenanceGate.disposition(
            for: Self.workload,
            phase: phase) == .proceed
    }
}

public enum MeetingMemoryGraphProjectionError: Error, Equatable {
    case invalidBatch
}
