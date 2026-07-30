import ApplicationKit
import Foundation
import PortavozCore

enum AppResourceGovernorAdmissionError: Error, Equatable, LocalizedError {
    case activeCaptureModelConflict

    var errorDescription: String? {
        switch self {
        case .activeCaptureModelConflict:
            L10n.text(
                "Finish the recording before starting another large on-device AI task.")
        }
    }
}

final class AppResourceCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ResourceCaptureState.inactive

    var current: ResourceCaptureState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ state: ResourceCaptureState) {
        lock.lock()
        self.state = state
        lock.unlock()
    }
}

enum AppResourceGovernorMaintenanceGate {
    static func make(
        captureState: AppResourceCaptureState
    ) -> DurableMaintenanceGate {
        DurableMaintenanceGate { descriptor, phase in
            disposition(
                for: descriptor,
                phase: phase,
                captureState: captureState.current)
        }
    }

    static func disposition(
        for descriptor: ResourceWorkloadDescriptor,
        phase: ResourceGovernorEvaluationPhase,
        captureState: ResourceCaptureState
    ) -> DurableMaintenanceDisposition {
        let decision = ResourceGovernorPolicy().evaluate(
            request: ResourceGovernorRequest(
                descriptor: descriptor,
                phase: phase),
            snapshot: ResourceGovernorSnapshot(
                capture: ResourceCaptureSnapshot(
                    state: captureState,
                    sourceHealth: .healthy),
                memoryTier: .unknown,
                diskState: .unknown,
                memoryPressure: .nominal,
                thermalState: .nominal,
                residentModels: [],
                hasForegroundAction: false,
                durableBacklog: .present,
                powerSource: .unknown,
                isLowPowerModeEnabled: false))

        switch decision.disposition {
        case .admitNow, .admitWithReducedConcurrency:
            return .proceed
        case .defer, .pauseAfterCheckpoint, .reject:
            return .pause
        }
    }
}

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
        let captureState = resourceCaptureState
        modelResidencyLedger.installIdleObserver { [weak self, weak monitor, captureState] _ in
            let pressure = monitor?.current ?? .nominal
            guard pressure.requestsIdleModelRelease
                    || captureState.current != .inactive
            else { return }
            Task { @MainActor [weak self] in
                await self?.reconcileModelPressure(pressure)
            }
        }
    }

    func recordingPhaseDidChange(_ phase: RecordingPhase) {
        let next = phase.resourceCaptureState
        resourceCaptureState.update(next)
        guard next != .inactive else {
            semanticIndexingSupervisor.kick()
            meetingSync.maintenanceMayResume()
            libraryMarkdownBackup.maintenanceMayResume()
            return
        }
        let pressure = resourcePressureMonitor?.current ?? .nominal
        Task { @MainActor [weak self] in
            await self?.reconcileModelPressure(pressure)
        }
    }

    func admitModelRuntimeLoad(
        _ family: ResourceModelFamily
    ) async throws {
        _ = try await reconcileModelRuntimeLoadAdmission(
            family,
            reservesLoad: false)
    }

    func beginAdmittedModelRuntimeLoad(
        _ family: ResourceModelFamily
    ) async throws -> ResourceModelLoadTicket? {
        try await reconcileModelRuntimeLoadAdmission(
            family,
            reservesLoad: true)
    }

    private func reconcileModelRuntimeLoadAdmission(
        _ family: ResourceModelFamily,
        reservesLoad: Bool
    ) async throws -> ResourceModelLoadTicket? {
        var decision = AppResourceGovernorModelLoadPlan.decision(
            target: family,
            captureState: resourceCaptureState.current,
            residencyRecords: modelResidencyLedger.records)
        await releaseIdleModels(decision.evictIdleModels)
        decision = AppResourceGovernorModelLoadPlan.decision(
            target: family,
            captureState: resourceCaptureState.current,
            residencyRecords: modelResidencyLedger.records)
        guard !AppResourceGovernorModelLoadPlan.blocks(
            decision: decision,
            target: family)
        else {
            throw AppResourceGovernorAdmissionError
                .activeCaptureModelConflict
        }
        // Keep the final decision and ledger transition in one MainActor turn.
        // Returning to the caller first would let two cross-family tasks both
        // observe an empty pair before either reserved its loading generation.
        return reservesLoad
            ? modelResidencyLedger.beginLoad(family)
            : nil
    }

    @discardableResult
    func reconcileModelPressure(
        _ pressure: AppResourcePressureSnapshot
    ) async -> [ResourceModelFamily] {
        let requested = AppResourceGovernorReleasePlan.families(
            pressure: pressure,
            captureState: resourceCaptureState.current,
            residentModels: modelResidencyLedger.residentModels)
        var released: [ResourceModelFamily] = []
        for family in requested where await releaseIdleModel(family) {
            released.append(family)
        }
        return released
    }

    private func releaseIdleModels(
        _ families: [ResourceModelFamily]
    ) async {
        for family in families {
            _ = await releaseIdleModel(family)
        }
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

enum AppResourceGovernorModelLoadPlan {
    static func decision(
        target: ResourceModelFamily,
        captureState: ResourceCaptureState,
        residencyRecords: [ResourceModelResidencyRecord]
    ) -> ResourceGovernorDecision {
        let request = ResourceGovernorRequest(
            descriptor: ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: workloadKind(for: target),
                operation: .load),
            phase: .admission)
        let snapshot = ResourceGovernorSnapshot(
            capture: ResourceCaptureSnapshot(
                state: captureState,
                sourceHealth: .healthy),
            memoryTier: .unknown,
            diskState: .unknown,
            memoryPressure: .nominal,
            thermalState: .nominal,
            residentModels: governorOccupancy(
                from: residencyRecords),
            hasForegroundAction: true,
            durableBacklog: .empty,
            powerSource: .unknown,
            isLowPowerModeEnabled: false)
        return ResourceGovernorPolicy().evaluate(
            request: request,
            snapshot: snapshot)
    }

    static func blocks(
        decision: ResourceGovernorDecision,
        target: ResourceModelFamily
    ) -> Bool {
        if case .defer(until: .captureStops) = decision.disposition {
            return true
        }
        guard let peer = peer(for: target) else { return false }
        return decision.evictIdleModels.contains(peer)
    }

    private static func workloadKind(
        for family: ResourceModelFamily
    ) -> ResourceWorkloadKind {
        switch family {
        case .qualitySpeech:
            .qualityTranscription
        case .languageIntelligence:
            .languageInference
        case .liveSpeech:
            .liveTranscription
        case .speakerDiarization:
            .speakerDiarization
        case .semanticEmbedding:
            .searchIndex
        }
    }

    private static func peer(
        for family: ResourceModelFamily
    ) -> ResourceModelFamily? {
        switch family {
        case .qualitySpeech:
            .languageIntelligence
        case .languageIntelligence:
            .qualitySpeech
        case .liveSpeech, .speakerDiarization, .semanticEmbedding:
            nil
        }
    }

    /// A runtime that is still loading already consumes the pair's admission
    /// slot even though it is not publishable or releasable yet. Project it as
    /// non-idle occupancy only for the governor decision; the concrete release
    /// path continues to accept resident idle families exclusively.
    private static func governorOccupancy(
        from records: [ResourceModelResidencyRecord]
    ) -> [ResourceResidentModel] {
        records.compactMap { record in
            guard record.status != .unloaded else { return nil }
            return ResourceResidentModel(
                family: record.family,
                measuredFootprintBytes: record.measuredFootprintBytes,
                isIdle: record.status != .loading
                    && record.activeUseCount == 0)
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
