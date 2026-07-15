import ApplicationKit
import Foundation
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
    var regenerateSummary: RegenerateSummary {
        RegenerateSummary(
            store: store,
            preferences: AppSummaryRegenerationPreferences(),
            providers: AppSummaryRegenerationProviderResolver(
                defaultEngine: summaryEngine,
                ollamaModel: ollamaModel,
                mlxModelDirectory: mlxDownloaded
                    ? Self.modelDir(ModelCatalog.mlxQwen35)
                    : nil))
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

private struct AppSummaryRegenerationProviderResolver: SummaryRegenerationProviderResolver {
    let defaultEngine: SummaryEngine
    let ollamaModel: String?
    let mlxModelDirectory: URL?

    func resolve(
        override: SummaryEngine?
    ) -> SummaryRegenerationProviderResolution {
        switch override ?? defaultEngine {
        case .ollama:
            if let ollamaModel {
                return .available(
                    AppDirectSummaryRegenerationProvider(
                        provider: OllamaService.summaryProvider(model: ollamaModel),
                        providerID: OllamaService.providerID(model: ollamaModel)))
            }
        case .mlx:
            if let mlxModelDirectory {
                return .available(
                    AppDirectSummaryRegenerationProvider(
                        provider: MLXSummaryProvider(modelDirectory: mlxModelDirectory),
                        providerID: MLXSummaryProvider.providerID))
            }
        case .appleOnDevice:
            break
        }

        guard #available(macOS 26.0, *) else {
            return .unavailable(.requiresMacOS26)
        }
        if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
            return .unavailable(.appleOnDevice(reason: reason))
        }
        return .available(AppFoundationSummaryRegenerationProvider())
    }
}

private enum AppSummaryRegenerationProviderError: Error {
    case translationUnsupported
}

private struct AppDirectSummaryRegenerationProvider: SummaryRegenerationProvider {
    let provider: any SummaryProvider
    let providerID: String
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
