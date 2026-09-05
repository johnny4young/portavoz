import Foundation
import PortavozCore

/// Single-flight, no-backlog admission for benchmark-only semantic shadows.
///
/// Every request is evaluated at the existing maintenance/search-index
/// boundary. Policy denial, capture suspension, and an occupied flight are
/// explicit skipped observations rather than queued work. Capture suspension
/// also cancels the active cooperative candidate.
public actor SemanticIndexShadowCoordinator {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let descriptor = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .searchIndex,
        operation: .execute)

    private let gate: DurableMaintenanceGate
    private var active: Flight?
    private var isSuspendedForCapture = false

    public init(gate: DurableMaintenanceGate) {
        self.gate = gate
    }

    nonisolated public var executor: SemanticIndexShadowExecutor {
        SemanticIndexShadowExecutor { operation, skipped in
            _ = Task(priority: .utility) {
                await self.submit(
                    operation: operation,
                    skipped: skipped)
            }
        }
    }

    public func suspendForCapture() {
        isSuspendedForCapture = true
        active?.task.cancel()
    }

    public func resumeAfterCapture() async {
        if let flight = active {
            await flight.task.value
            if active?.id == flight.id {
                active = nil
            }
        }
        isSuspendedForCapture = false
    }

    private func submit(
        operation: @escaping @Sendable () async -> Void,
        skipped: @escaping @Sendable (SemanticIndexShadowSkipReason) -> Void
    ) async {
        guard !isSuspendedForCapture else {
            skipped(.capture)
            return
        }
        guard gate.disposition(
            for: Self.descriptor,
            phase: .admission) == .proceed
        else {
            skipped(.policy)
            return
        }
        guard active == nil else {
            skipped(.busy)
            return
        }

        let id = UUID()
        let task = Task(priority: .utility) {
            await operation()
        }
        active = Flight(id: id, task: task)
        await task.value
        if active?.id == id {
            active = nil
        }
    }
}
