import PortavozCore

/// Narrow application boundary between durable work and the process resource
/// governor. Capability use cases ask whether they may start or continue; the
/// executable composition root owns the live host snapshot and policy mapping.
public enum DurableMaintenanceDisposition: Equatable, Sendable {
    case proceed
    case pause
}

public struct DurableMaintenanceGate: Sendable {
    private let evaluate: @Sendable (
        _ descriptor: ResourceWorkloadDescriptor,
        _ phase: ResourceGovernorEvaluationPhase
    ) -> DurableMaintenanceDisposition

    public init(
        _ evaluate: @escaping @Sendable (
            _ descriptor: ResourceWorkloadDescriptor,
            _ phase: ResourceGovernorEvaluationPhase
        ) -> DurableMaintenanceDisposition
    ) {
        self.evaluate = evaluate
    }

    /// Non-app products and isolated use-case tests remain deterministic until
    /// their composition roots explicitly install resource policy.
    public static let unrestricted = Self { _, _ in .proceed }

    public func disposition(
        for descriptor: ResourceWorkloadDescriptor,
        phase: ResourceGovernorEvaluationPhase
    ) -> DurableMaintenanceDisposition {
        evaluate(descriptor, phase)
    }
}
