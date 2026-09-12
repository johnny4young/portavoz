import ApplicationKit
import Foundation
import ModelStoreKit
import PlatformKit
import PortavozCore

extension AppServices {
    func exportSupportDiagnostics() async throws -> Data {
        try await ExportSupportDiagnostics(
            store: store,
            telemetry: workloadTelemetry).execute(
            ExportSupportDiagnosticsRequest(
                environment: SupportDiagnosticsEnvironment(
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        ?? "development",
                    buildVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion") as? String
                        ?? "development",
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    models: await supportModelReadiness(),
                    host: supportHostDiagnostics())))
    }

    func supportHostDiagnostics(
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        readProcess: () throws -> OwnProcessResourceUsage = { try .current() }
    ) -> SupportHostDiagnostics {
        let process = try? readProcess()
        // A conservative governor fallback is not an observed host fact.
        let observedThermal: ResourceThermalState? = switch thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: nil
        }
        let info = ProcessInfo.processInfo
        return SupportHostDiagnostics(
            physicalMemoryBytes: info.physicalMemory,
            processFootprintBytes: process?.physicalFootprintBytes,
            processCPUSeconds: process?.cpuSeconds,
            thermalState: observedThermal,
            lowPowerModeEnabled: info.isLowPowerModeEnabled,
            modelResidency: modelResidencyLedger.records)
    }

    private func supportModelReadiness() async -> [SupportModelReadiness] {
        async let variants = whisperVariants()
        async let mlxInstallation = modelLifecycle.installation(
            for: ModelCatalog.mlxQwen35)
        let resolvedVariants = await variants
        let mlxIsInstalled = await mlxInstallation != nil
        return [
            SupportModelReadiness(
                capability: "live-transcription-runtime",
                state: runtimeState(
                    loaded: transcriber != nil,
                    preparing: liveSpeechRuntimeLoad != nil)),
            SupportModelReadiness(
                capability: "speaker-diarization-runtime",
                state: runtimeState(
                    loaded: diarizationRuntime != nil,
                    preparing: diarizationRuntimeLoad != nil)),
            SupportModelReadiness(
                capability: "speech-runtime-preparation",
                state: speechPreparationState),
            SupportModelReadiness(
                capability: "whisper-turbo",
                state: whisperState(
                    for: resolvedVariants.first(where: { !$0.compact }))),
            SupportModelReadiness(
                capability: "whisper-compact",
                state: whisperState(
                    for: resolvedVariants.first(where: \.compact))),
            SupportModelReadiness(
                capability: "apple-foundation-models",
                state: foundationModelsCapability.isAvailable ? .available : .unavailable),
            SupportModelReadiness(
                capability: "embedded-mlx-summary",
                state: mlxIsInstalled ? .installed : .notInstalled),
            SupportModelReadiness(
                capability: "ollama-summary",
                state: ollamaModel == nil ? .notConfigured : .configured)
        ]
    }

    private func runtimeState(loaded: Bool, preparing: Bool) -> SupportModelReadinessState {
        if loaded { return .loaded }
        if preparing { return .preparing }
        return .notLoaded
    }

    private var speechPreparationState: SupportModelReadinessState {
        switch modelsState {
        case .unknown: .notLoaded
        case .downloading: .preparing
        case .ready: .loaded
        case .failed: .failed
        }
    }

    private func whisperState(for variant: WhisperVariant?) -> SupportModelReadinessState {
        guard let variant else { return .notInstalled }
        switch whisperPreparationState {
        case .preparing(let id, _, _, _) where id == variant.id:
            return .preparing
        case .ready(let id) where id == variant.id:
            return .installed
        case .failed(let id, _) where id == variant.id:
            return .failed
        default:
            return variant.downloaded ? .installed : .notInstalled
        }
    }
}
