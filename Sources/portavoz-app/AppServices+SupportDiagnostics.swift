import ApplicationKit
import Foundation
import ModelStoreKit

extension AppServices {
    func exportSupportDiagnostics() async throws -> Data {
        try await ExportSupportDiagnostics(store: store).execute(
            ExportSupportDiagnosticsRequest(
                environment: SupportDiagnosticsEnvironment(
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        ?? "development",
                    buildVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion") as? String
                        ?? "development",
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    models: await supportModelReadiness())))
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
                state: runtimeState(loaded: transcriber != nil, preparing: transcriberLoadTask != nil)),
            SupportModelReadiness(
                capability: "speaker-diarization-runtime",
                state: runtimeState(loaded: diarizer != nil, preparing: diarizerLoadTask != nil)),
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
        switch whisperDownloadState {
        case .downloading(let id, _, _) where id == variant.id:
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
