/// Narrow boundary between durable work and a process resource governor.
/// Capability owners ask whether they may start or continue; executable
/// composition roots own the live host snapshot and policy mapping.
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
