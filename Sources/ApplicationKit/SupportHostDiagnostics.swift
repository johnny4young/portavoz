import Foundation
import PortavozCore

/// One requested snapshot, not a monitor, a latency benchmark or a history.
/// Runtime-family footprints are optional owner measurements, never estimates
/// obtained by dividing the process footprint among loaded models.
public struct SupportHostDiagnostics: Codable, Equatable, Sendable {
    public let physicalMemoryBytes: UInt64
    public let processFootprintBytes: UInt64?
    public let processCPUSeconds: Double?
    public let thermalState: ResourceThermalState?
    public let lowPowerModeEnabled: Bool
    public let modelResidency: [ResourceModelResidencyRecord]

    public init(
        physicalMemoryBytes: UInt64,
        processFootprintBytes: UInt64?,
        processCPUSeconds: Double?,
        thermalState: ResourceThermalState?,
        lowPowerModeEnabled: Bool,
        modelResidency: [ResourceModelResidencyRecord]
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processFootprintBytes = processFootprintBytes
        self.processCPUSeconds = processCPUSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        // One unambiguous observation per closed family, in canonical order.
        // Invalid or conflicting owner evidence stays absent, not zero/idle.
        self.modelResidency = ResourceModelFamily.allCases.compactMap { family in
            var matching = modelResidency.lazy.filter { $0.family == family }.makeIterator()
            guard let record = matching.next(), matching.next() == nil, record.activeUseCount >= 0 else { return nil }
            return record
        }
    }

    var sanitized: Self {
        Self(
            physicalMemoryBytes: physicalMemoryBytes, processFootprintBytes: processFootprintBytes,
            processCPUSeconds: processCPUSeconds, thermalState: thermalState,
            lowPowerModeEnabled: lowPowerModeEnabled, modelResidency: modelResidency)
    }
}
