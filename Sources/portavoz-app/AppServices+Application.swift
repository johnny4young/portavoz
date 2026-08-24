import ApplicationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import StorageKit
import TranscriptionKit

extension AppServices {
    /// ApplicationKit commands composed from the real local adapters.
    var meetingLifecycle: MeetingLifecycleUseCases { .init(store: store) }
    var meetingPurge: MeetingPurgeUseCases {
        .init(store: store, audioFiles: AppMeetingAudioFiles())
    }
    /// One resolver literal shared by every generation use case, so a new
    /// consumer inherits FM/Ollama/MLX/BYOK routing without duplication.
    var summaryProviderResolver: AppSummaryRegenerationProviderResolver {
        AppSummaryRegenerationProviderResolver(
            defaultEngine: summaryEngine,
            ollamaModel: ollamaModel,
            mlxModelDirectory: { [modelLifecycle] in
                await modelLifecycle.installation(for: ModelCatalog.mlxQwen35)?.directory
            },
            mlxProvider: { [weak self] directory, priority in
                guard let self else {
                    return AppUnavailableSummaryProvider()
                }
                return self.makeMLXSummaryProvider(
                    modelDirectory: directory,
                    priority: priority)
            },
            foundationModelsCapability: foundationModelsCapability,
            gateway: dataEgressGateway)
    }

    var regenerateSummary: RegenerateSummary {
        RegenerateSummary(
            store: store,
            preferences: AppSummaryRegenerationPreferences(),
            providers: summaryProviderResolver)
    }

    var enhanceMeetingNotes: EnhanceMeetingNotes {
        EnhanceMeetingNotes(
            store: store,
            preferences: AppSummaryRegenerationPreferences(),
            providers: summaryProviderResolver)
    }

    /// Resolves the opt-in Companion client from app preferences plus the
    /// async secret workflow. IntelligenceKit receives only explicit values.
    func companionBYOKClient() async -> CompanionBYOKClient? {
        let defaults = UserDefaults.standard
        return BYOKSettings.companionClient(
            isEnabled: defaults.bool(forKey: BYOKSettings.companionEnabledKey),
            endpoint: defaults.string(forKey: BYOKSettings.endpointKey) ?? "",
            model: defaults.string(forKey: BYOKSettings.modelKey) ?? "",
            apiKey: try? await secrets.value(for: .byokAPIKey),
            gateway: dataEgressGateway)
    }
}

/// Production filesystem adapter for permanent meeting-audio removal.
private struct AppMeetingAudioFiles: MeetingAudioFiles {
    func removeAudioDirectory(_ relativePath: String) throws {
        let directory = RecordingsLocation.shared.resolve(relativePath)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

private struct AppSummaryRegenerationPreferences: SummaryRegenerationPreferences {
    func glossary() -> [String] {
        VocabularyPrompt.parse(
            UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
    }
}

struct AppSummaryRegenerationProviderResolver: SummaryRegenerationProviderResolver {
    let defaultEngine: SummaryEngine
    let ollamaModel: String?
    let mlxModelDirectory: @Sendable () async -> URL?
    let mlxProvider: @MainActor @Sendable (
        _ directory: URL,
        _ priority: IntelligenceScheduler.Priority
    ) -> any SummaryProvider
    let foundationModelsCapability: FoundationModelsCapability
    let gateway: any DataEgressGateway

    func resolve(
        override: SummaryEngine?
    ) async -> SummaryRegenerationProviderResolution {
        switch override ?? defaultEngine {
        case .ollama:
            guard let ollamaModel else {
                return .unavailable(.ollamaModelNotSelected)
            }
            return .available(
                AppDirectSummaryRegenerationProvider(
                    provider: OllamaService.summaryProvider(
                        model: ollamaModel,
                        gateway: gateway,
                        consentSource: .summaryEngineSettings),
                    providerID: OllamaService.providerID(model: ollamaModel),
                    modelID: ollamaModel,
                    modelRevision: nil))
        case .mlx:
            guard let mlxModelDirectory = await mlxModelDirectory() else {
                return .unavailable(.mlxModelNotDownloaded)
            }
            return .available(
                AppDirectSummaryRegenerationProvider(
                    provider: await mlxProvider(
                        mlxModelDirectory,
                        .interactive),
                    providerID: MLXSummaryProvider.providerID,
                    modelID: ModelCatalog.mlxQwen35.id,
                    modelRevision: ModelCatalog.mlxQwen35.revision))
        case .appleOnDevice:
            break
        }

        switch foundationModelsCapability {
        case .requiresMacOS26:
            return .unavailable(.requiresMacOS26)
        case .unavailable(let reason):
            return .unavailable(.appleOnDevice(reason: reason))
        case .available:
            break
        }
        guard #available(macOS 26.0, *) else {
            return .unavailable(.requiresMacOS26)
        }
        return .available(AppFoundationSummaryRegenerationProvider())
    }

    /// Samples the same explicit engine choice for manual Ask without
    /// borrowing summary output contracts or silently falling through to a
    /// different provider when the selected engine is unavailable.
    func resolveAsk(
        mlxProvider: @MainActor @Sendable (
            _ directory: URL,
            _ priority: IntelligenceScheduler.Priority
        ) -> any RAGTextAnswering
    ) async -> AppAskAnswerProviderResolution {
        switch defaultEngine {
        case .ollama:
            guard let ollamaModel else {
                return .unavailable(.ollamaModelNotSelected)
            }
            return .available(OllamaService.askAnswerer(
                model: ollamaModel,
                gateway: gateway))
        case .mlx:
            guard let directory = await mlxModelDirectory() else {
                return .unavailable(.mlxModelNotDownloaded)
            }
            return .available(await mlxProvider(directory, .interactive))
        case .appleOnDevice:
            break
        }

        switch foundationModelsCapability {
        case .requiresMacOS26:
            return .unavailable(.requiresMacOS26)
        case .unavailable(let reason):
            return .unavailable(.appleOnDevice(reason: reason))
        case .available:
            break
        }
        guard #available(macOS 26.0, *) else {
            return .unavailable(.requiresMacOS26)
        }
        return .available(RAGAnswerer())
    }
}

private enum AppSummaryRegenerationProviderError: Error {
    case translationUnsupported
}

struct AppUnavailableSummaryProvider: SummaryProvider {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        throw CancellationError()
    }
}

private struct AppDirectSummaryRegenerationProvider: SummaryRegenerationProvider {
    let provider: any SummaryProvider
    let providerID: String
    let modelID: String
    let modelRevision: String?
    let reusePolicy = SummaryRegenerationReusePolicy.none
    let failurePresentation = SummaryRegenerationFailurePresentation.localModelNotice

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        try await provider.summarize(request)
    }

    func translate(
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String]
    ) async throws -> SummaryDraft {
        throw AppSummaryRegenerationProviderError.translationUnsupported
    }
}

@available(macOS 26.0, *)
private struct AppFoundationSummaryRegenerationProvider: SummaryRegenerationProvider {
    let providerID = FoundationModelSummaryProvider.providerID
    let modelID = "system-language-model"
    let modelRevision: String? = nil
    let reusePolicy = SummaryRegenerationReusePolicy.fingerprintCacheAndTranslationPivot
    let failurePresentation = SummaryRegenerationFailurePresentation.silent
    private let provider = FoundationModelSummaryProvider()

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        try await provider.summarize(request)
    }

    func translate(
        _ pivot: SummaryDraft,
        to targetLanguage: String,
        glossary: [String]
    ) async throws -> SummaryDraft {
        try await provider.translate(
            pivot,
            to: targetLanguage,
            glossary: glossary)
    }
}
