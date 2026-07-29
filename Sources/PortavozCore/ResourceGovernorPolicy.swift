/// Capture lifecycle visible to resource policy.
public enum ResourceCaptureState: String, CaseIterable, Sendable {
    case inactive
    case starting
    case active
    case stopping

    var protectsLiveCapture: Bool {
        self != .inactive
    }
}

/// Health of the selected capture sources before or during a recording.
public enum ResourceCaptureSourceHealth: String, CaseIterable, Sendable {
    case healthy
    case degraded
    case failed
}

/// Coarse hardware class. Numeric thresholds remain outside policy until they
/// are backed by accepted multi-host evidence.
public enum ResourceMemoryTier: String, CaseIterable, Sendable {
    case unknown
    case constrained
    case standard
    case large
}

public enum ResourceDiskState: String, CaseIterable, Sendable {
    case unknown
    case sufficient
    case low
    case critical
}

public enum ResourceMemoryPressure: String, CaseIterable, Sendable {
    case nominal
    case warning
    case critical
}

public enum ResourceThermalState: String, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum ResourcePowerSource: String, CaseIterable, Sendable {
    case unknown
    case external
    case battery
}

public enum ResourceDurableBacklog: String, CaseIterable, Sendable {
    case empty
    case present
    case saturated
}

/// Heavyweight runtime families. Values are capability identities, not model
/// names, file paths, or provider payloads.
public enum ResourceModelFamily: String, CaseIterable, Sendable {
    case liveSpeech
    case qualitySpeech
    case speakerDiarization
    case languageIntelligence
    case semanticEmbedding
}

public struct ResourceResidentModel: Equatable, Sendable {
    public let family: ResourceModelFamily
    public let measuredFootprintBytes: UInt64?
    public let isIdle: Bool

    public init(
        family: ResourceModelFamily,
        measuredFootprintBytes: UInt64?,
        isIdle: Bool
    ) {
        self.family = family
        self.measuredFootprintBytes = measuredFootprintBytes
        self.isIdle = isIdle
    }
}

public struct ResourceCaptureSnapshot: Equatable, Sendable {
    public let state: ResourceCaptureState
    public let sourceHealth: ResourceCaptureSourceHealth

    public init(
        state: ResourceCaptureState,
        sourceHealth: ResourceCaptureSourceHealth
    ) {
        self.state = state
        self.sourceHealth = sourceHealth
    }
}

/// One immutable, content-free view of host and product pressure.
public struct ResourceGovernorSnapshot: Equatable, Sendable {
    public let capture: ResourceCaptureSnapshot
    public let memoryTier: ResourceMemoryTier
    public let diskState: ResourceDiskState
    public let memoryPressure: ResourceMemoryPressure
    public let thermalState: ResourceThermalState
    public let residentModels: [ResourceResidentModel]
    public let hasForegroundAction: Bool
    public let durableBacklog: ResourceDurableBacklog
    public let powerSource: ResourcePowerSource
    public let isLowPowerModeEnabled: Bool

    public init(
        capture: ResourceCaptureSnapshot,
        memoryTier: ResourceMemoryTier,
        diskState: ResourceDiskState,
        memoryPressure: ResourceMemoryPressure,
        thermalState: ResourceThermalState,
        residentModels: [ResourceResidentModel],
        hasForegroundAction: Bool,
        durableBacklog: ResourceDurableBacklog,
        powerSource: ResourcePowerSource,
        isLowPowerModeEnabled: Bool
    ) {
        self.capture = capture
        self.memoryTier = memoryTier
        self.diskState = diskState
        self.memoryPressure = memoryPressure
        self.thermalState = thermalState
        self.residentModels = residentModels
        self.hasForegroundAction = hasForegroundAction
        self.durableBacklog = durableBacklog
        self.powerSource = powerSource
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

/// Whether policy is admitting new work or re-evaluating work at a durable
/// checkpoint.
public enum ResourceGovernorEvaluationPhase: String, CaseIterable, Sendable {
    case admission
    case checkpoint
}

public struct ResourceGovernorRequest: Equatable, Sendable {
    public let descriptor: ResourceWorkloadDescriptor
    public let phase: ResourceGovernorEvaluationPhase

    public init(
        descriptor: ResourceWorkloadDescriptor,
        phase: ResourceGovernorEvaluationPhase
    ) {
        self.descriptor = descriptor
        self.phase = phase
    }
}

public enum ResourceDeferralCondition: String, CaseIterable, Sendable {
    case captureStops
    case hostRecovers
    case storageAvailable
    case externalPower
    case lowPowerModeDisabled
}

public enum ResourceRecoveryAction: String, CaseIterable, Sendable {
    case freeDiskSpace
    case restoreAudioInput
    case waitForSystemToRecover
}

public enum ResourceAdmissionDisposition: Equatable, Sendable {
    case admitNow
    case admitWithReducedConcurrency
    case `defer`(until: ResourceDeferralCondition)
    case pauseAfterCheckpoint
    case reject(recovery: ResourceRecoveryAction)
}

/// Policy result. Admission and eviction are independent because a request can
/// proceed only after releasing unrelated idle model families.
public struct ResourceGovernorDecision: Equatable, Sendable {
    public let disposition: ResourceAdmissionDisposition
    public let evictIdleModels: [ResourceModelFamily]

    public init(
        disposition: ResourceAdmissionDisposition,
        evictIdleModels: [ResourceModelFamily] = []
    ) {
        self.disposition = disposition
        self.evictIdleModels = evictIdleModels
    }
}

/// Pure GOV-1 policy. It performs no I/O, scheduling, model loading, or
/// eviction; application adapters execute the returned decision.
public struct ResourceGovernorPolicy: Sendable {
    public init() {}

    public func evaluate(
        request: ResourceGovernorRequest,
        snapshot: ResourceGovernorSnapshot
    ) -> ResourceGovernorDecision {
        let descriptor = request.descriptor
        let targetModel = descriptor.operation == .release
            ? nil
            : descriptor.modelFamily
        let evictions = idleModelEvictions(
            snapshot: snapshot,
            preserving: targetModel)

        if descriptor.workloadClass == .recordingCritical {
            return evaluateRecordingCritical(
                request: request,
                snapshot: snapshot,
                evictions: evictions)
        }

        if descriptor.operation == .release {
            return ResourceGovernorDecision(
                disposition: .admitNow,
                evictIdleModels: evictions)
        }

        if snapshot.diskState == .critical, descriptor.writesDurableData {
            return deferredOrRejectedForStorage(
                request: request,
                snapshot: snapshot,
                evictions: evictions)
        }

        if snapshot.capture.state.protectsLiveCapture {
            return evaluateDuringCapture(
                request: request,
                snapshot: snapshot,
                evictions: evictions)
        }

        if snapshot.hasSeverePressure {
            if descriptor.workloadClass == .liveInteractive {
                return ResourceGovernorDecision(
                    disposition: .admitWithReducedConcurrency,
                    evictIdleModels: evictions)
            }
            return deferredPausedOrRejectedForPressure(
                request: request,
                snapshot: snapshot,
                evictions: evictions)
        }

        let powerDeferral = snapshot.maintenancePowerDeferral
        if descriptor.workloadClass == .maintenance, let powerDeferral {
            return ResourceGovernorDecision(
                disposition: request.phase == .checkpoint
                    ? .pauseAfterCheckpoint
                    : .defer(until: powerDeferral),
                evictIdleModels: evictions)
        }

        if snapshot.hasModeratePressure {
            return ResourceGovernorDecision(
                disposition: .admitWithReducedConcurrency,
                evictIdleModels: evictions)
        }

        return ResourceGovernorDecision(
            disposition: .admitNow,
            evictIdleModels: evictions)
    }

    private func evaluateRecordingCritical(
        request: ResourceGovernorRequest,
        snapshot: ResourceGovernorSnapshot,
        evictions: [ResourceModelFamily]
    ) -> ResourceGovernorDecision {
        let isCapturePreflight =
            request.phase == .admission
                && request.descriptor.kind == .audioCapture
                && !snapshot.capture.state.protectsLiveCapture

        if isCapturePreflight, snapshot.capture.sourceHealth == .failed {
            return ResourceGovernorDecision(
                disposition: .reject(recovery: .restoreAudioInput),
                evictIdleModels: evictions)
        }
        if isCapturePreflight, snapshot.diskState == .critical {
            return ResourceGovernorDecision(
                disposition: .reject(recovery: .freeDiskSpace),
                evictIdleModels: evictions)
        }

        return ResourceGovernorDecision(
            disposition: .admitNow,
            evictIdleModels: evictions)
    }

    private func evaluateDuringCapture(
        request: ResourceGovernorRequest,
        snapshot: ResourceGovernorSnapshot,
        evictions: [ResourceModelFamily]
    ) -> ResourceGovernorDecision {
        let descriptor = request.descriptor

        let isDurableOptionalWork =
            descriptor.workloadClass == .maintenance
                || descriptor.workloadClass == .postCapture
        if isDurableOptionalWork {
            return ResourceGovernorDecision(
                disposition: request.phase == .checkpoint
                    ? .pauseAfterCheckpoint
                    : .defer(until: .captureStops),
                evictIdleModels: evictions)
        }

        let heavyUserWorkShouldWait =
            descriptor.workloadClass == .userInitiated
                && descriptor.requiresHeavyModelResidency
                && (snapshot.memoryTier == .constrained || snapshot.hasModeratePressure)
        if heavyUserWorkShouldWait {
            return ResourceGovernorDecision(
                disposition: request.phase == .checkpoint
                    ? .pauseAfterCheckpoint
                    : .defer(until: .captureStops),
                evictIdleModels: evictions)
        }

        return ResourceGovernorDecision(
            disposition: snapshot.hasModeratePressure
                || descriptor.workloadClass == .userInitiated
                ? .admitWithReducedConcurrency
                : .admitNow,
            evictIdleModels: evictions)
    }

    private func deferredOrRejectedForStorage(
        request: ResourceGovernorRequest,
        snapshot: ResourceGovernorSnapshot,
        evictions: [ResourceModelFamily]
    ) -> ResourceGovernorDecision {
        if request.phase == .checkpoint {
            return ResourceGovernorDecision(
                disposition: .pauseAfterCheckpoint,
                evictIdleModels: evictions)
        }
        let isForeground =
            snapshot.hasForegroundAction
                || request.descriptor.workloadClass == .userInitiated
        if isForeground {
            return ResourceGovernorDecision(
                disposition: .reject(recovery: .freeDiskSpace),
                evictIdleModels: evictions)
        }
        return ResourceGovernorDecision(
            disposition: .defer(until: .storageAvailable),
            evictIdleModels: evictions)
    }

    private func deferredPausedOrRejectedForPressure(
        request: ResourceGovernorRequest,
        snapshot: ResourceGovernorSnapshot,
        evictions: [ResourceModelFamily]
    ) -> ResourceGovernorDecision {
        if request.phase == .checkpoint {
            return ResourceGovernorDecision(
                disposition: .pauseAfterCheckpoint,
                evictIdleModels: evictions)
        }
        let isForeground =
            snapshot.hasForegroundAction
                || request.descriptor.workloadClass == .userInitiated
        if isForeground {
            return ResourceGovernorDecision(
                disposition: .reject(recovery: .waitForSystemToRecover),
                evictIdleModels: evictions)
        }
        return ResourceGovernorDecision(
            disposition: .defer(until: .hostRecovers),
            evictIdleModels: evictions)
    }

    private func idleModelEvictions(
        snapshot: ResourceGovernorSnapshot,
        preserving target: ResourceModelFamily?
    ) -> [ResourceModelFamily] {
        guard snapshot.hasModeratePressure else { return [] }
        let idleFamilies = Set(
            snapshot.residentModels.lazy
                .filter(\.isIdle)
                .map(\.family))
        return ResourceModelFamily.allCases.filter {
            idleFamilies.contains($0) && $0 != target
        }
    }
}

private extension ResourceGovernorSnapshot {
    var maintenancePowerDeferral: ResourceDeferralCondition? {
        if isLowPowerModeEnabled {
            return .lowPowerModeDisabled
        }
        if powerSource == .battery {
            return .externalPower
        }
        return nil
    }

    var hasModeratePressure: Bool {
        memoryPressure != .nominal
            || thermalState == .serious
            || thermalState == .critical
    }

    var hasSeverePressure: Bool {
        memoryPressure == .critical || thermalState == .critical
    }
}

private extension ResourceWorkloadDescriptor {
    var modelFamily: ResourceModelFamily? {
        switch kind {
        case .liveTranscription:
            .liveSpeech
        case .qualityTranscription:
            .qualitySpeech
        case .speakerDiarization:
            .speakerDiarization
        case .languageInference:
            .languageIntelligence
        case .searchIndex:
            .semanticEmbedding
        case .audioCapture, .librarySync, .waveform, .uiProjection,
             .mediaExport, .supportExport:
            nil
        }
    }

    var requiresHeavyModelResidency: Bool {
        modelFamily != nil && operation != .release
    }

    var writesDurableData: Bool {
        switch kind {
        case .audioCapture, .qualityTranscription, .speakerDiarization,
             .languageInference, .searchIndex, .librarySync, .waveform,
             .mediaExport, .supportExport:
            true
        case .liveTranscription, .uiProjection:
            false
        }
    }
}
