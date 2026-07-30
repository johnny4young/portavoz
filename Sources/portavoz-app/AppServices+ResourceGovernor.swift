import Foundation
import PortavozCore

extension AppServices {
    /// Starts the narrow first application adapter for the pure governor:
    /// pressure-driven release of idle resident models. UI automation and
    /// isolated resource benchmarks stay deterministic and install no host
    /// observer.
    func startResourcePressureMonitoring() {
        guard resourcePressureMonitor == nil,
              !ProcessInfo.processInfo.arguments.contains("-use-temp-store")
        else { return }

        let monitor = AppResourcePressureMonitor { [weak self] pressure in
            guard pressure.requestsIdleModelRelease else { return }
            Task { @MainActor [weak self] in
                await self?.reconcileModelPressure(pressure)
            }
        }
        resourcePressureMonitor = monitor
        modelResidencyLedger.installIdleObserver { [weak self, weak monitor] _ in
            guard let pressure = monitor?.current,
                  pressure.requestsIdleModelRelease
            else { return }
            Task { @MainActor [weak self] in
                await self?.reconcileModelPressure(pressure)
            }
        }
    }

    @discardableResult
    func reconcileModelPressure(
        _ pressure: AppResourcePressureSnapshot
    ) async -> [ResourceModelFamily] {
        let requested = AppResourceGovernorReleasePlan.families(
            pressure: pressure,
            captureState: recording.phase.resourceCaptureState,
            residentModels: modelResidencyLedger.residentModels)
        var released: [ResourceModelFamily] = []
        for family in requested where await releaseIdleModel(family) {
            released.append(family)
        }
        return released
    }

    @discardableResult
    private func releaseIdleModel(
        _ family: ResourceModelFamily
    ) async -> Bool {
        switch family {
        case .liveSpeech:
            releaseLiveSpeechRuntime()
        case .qualitySpeech:
            releaseWhisper()
        case .speakerDiarization:
            releaseDiarizationRuntime()
        case .languageIntelligence:
            await releaseMLXRuntime()
        case .semanticEmbedding:
            await semanticEmbeddingRuntime.release()
        }
    }
}

enum AppResourceGovernorReleasePlan {
    static func families(
        pressure: AppResourcePressureSnapshot,
        captureState: ResourceCaptureState,
        residentModels: [ResourceResidentModel]
    ) -> [ResourceModelFamily] {
        let request = ResourceGovernorRequest(
            descriptor: ResourceWorkloadDescriptor(
                workloadClass: .maintenance,
                kind: .uiProjection,
                operation: .release),
            phase: .admission)
        let snapshot = ResourceGovernorSnapshot(
            capture: ResourceCaptureSnapshot(
                state: captureState,
                sourceHealth: .healthy),
            memoryTier: .unknown,
            diskState: .unknown,
            memoryPressure: pressure.memory,
            thermalState: pressure.thermal,
            residentModels: residentModels,
            hasForegroundAction: false,
            durableBacklog: .empty,
            powerSource: .unknown,
            isLowPowerModeEnabled: false)
        return ResourceGovernorPolicy().evaluate(
            request: request,
            snapshot: snapshot
        ).evictIdleModels
    }
}

private extension RecordingPhase {
    var resourceCaptureState: ResourceCaptureState {
        switch self {
        case .idle, .done, .failed:
            .inactive
        case .preparing:
            .starting
        case .recording:
            .active
        case .processing:
            .stopping
        }
    }
}
