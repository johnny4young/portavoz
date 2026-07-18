import ApplicationKit
import DiarizationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import PlatformKit
import PortavozCore
import StorageKit

/// The sole construction surface for product-facing CLI commands. Commands
/// receive application workflows and retain only parsing and terminal output.
struct CLIComposition {
    let platform: CLIPlatformDependencies
    private let store: MeetingStore
    let library: QueryMeetingLibrary
    let ask: AskMeetings

    static func open(
        dbPath: String?,
        platform: CLIPlatformDependencies
    ) throws -> Self {
        let store: MeetingStore
        if let dbPath {
            store = try MeetingStore(databaseURL: URL(fileURLWithPath: dbPath))
        } else {
            store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
        }
        return Self(
            platform: platform,
            store: store,
            library: .local(store: store),
            ask: .local(store: store))
    }
}

/// Process-wide concrete platform/security dependencies for CLI product
/// commands. Benchmark harnesses intentionally retain isolated construction.
struct CLIPlatformDependencies {
    let secretStorage: KeychainSecretStore
    let secrets: ManageSecrets
    let voiceprintStore: VoiceprintStore
    let voiceGallery: VoiceGallery
    var defaultClusteringThreshold: Float {
        PyannoteDiarizer.defaultClusteringThreshold
    }

    init() {
        let secretStorage = KeychainSecretStore()
        self.secretStorage = secretStorage
        secrets = ManageSecrets(storage: secretStorage)
        voiceprintStore = VoiceprintStore(secrets: secretStorage)
        voiceGallery = VoiceGallery(secrets: secretStorage)
    }

    /// Keychain is authoritative when it contains a non-empty value. A
    /// temporary Keychain failure or an absent value may still use the
    /// command's explicit environment-variable fallback.
    func credential(
        for identifier: SecretIdentifier,
        environmentVariable: String
    ) async -> String? {
        if let stored = try? await secrets.value(for: identifier),
           !stored.isEmpty {
            return stored
        }
        guard let fallback = ProcessInfo.processInfo.environment[environmentVariable],
              !fallback.isEmpty
        else { return nil }
        return fallback
    }

    func transcribeAudio(modelsDirectory: String?) -> TranscribeAudioFile {
        TranscribeAudioFile(
            files: CLIFileAdapter(),
            processor: CLIAudioTranscriptionProcessor(
                modelsDirectory: modelsDirectory))
    }

    func diarizeAudio(modelsDirectory: String?) -> DiarizeAudioFile {
        DiarizeAudioFile(
            files: CLIFileAdapter(),
            processor: CLIAudioDiarizationProcessor(
                modelsDirectory: modelsDirectory,
                voiceprintStore: voiceprintStore))
    }

    func summarizeAudio(
        modelsDirectory: String?,
        provider configuration: CLISummaryProviderConfiguration,
        store: MeetingStore?
    ) throws -> SummarizeAudioFile {
        let provider: any SummaryProvider
        switch configuration {
        case .byok(let endpoint, let model, let apiKey):
            provider = OpenAICompatibleSummaryProvider(
                endpoint: endpoint,
                model: model,
                apiKey: apiKey,
                gateway: URLSessionDataEgressGateway(receiptRecorder: store))
        case .onDevice:
            guard #available(macOS 26.0, *) else {
                throw CLISummaryProviderConfigurationError.requiresMacOS26
            }
            if let reason = FoundationModelSummaryProvider.unavailabilityReason() {
                throw CLISummaryProviderConfigurationError.unavailable(reason)
            }
            provider = FoundationModelSummaryProvider()
        }
        return SummarizeAudioFile(
            files: CLIFileAdapter(),
            processor: CLIAudioSummaryProcessor(
                modelsDirectory: modelsDirectory,
                voiceprintStore: voiceprintStore,
                provider: provider),
            store: store)
    }

    func voiceIdentity(modelsDirectory: String?) -> ManageLocalVoiceIdentity {
        ManageLocalVoiceIdentity(
            files: CLIFileAdapter(),
            identities: CLILocalVoiceIdentityStore(store: voiceprintStore),
            extractor: CLILocalVoiceIdentityExtractor(
                modelsDirectory: modelsDirectory))
    }

    func localModels(modelsDirectory: String?) -> ManageLocalModels {
        ManageLocalModels(models: CLILocalModelLifecycleManager(
            modelsDirectory: modelsDirectory))
    }
}

enum CLISummaryProviderConfiguration: Sendable {
    case onDevice
    case byok(endpoint: URL, model: String, apiKey: String)
}

enum CLISummaryProviderConfigurationError: Error, LocalizedError {
    case requiresMacOS26
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            "on-device summaries need macOS 26+; use --byok as an explicit fallback"
        case .unavailable(let reason):
            reason
        }
    }
}

extension CLIComposition {
    func summarizeAudio(
        modelsDirectory: String?,
        provider configuration: CLISummaryProviderConfiguration
    ) throws -> SummarizeAudioFile {
        try platform.summarizeAudio(
            modelsDirectory: modelsDirectory,
            provider: configuration,
            store: store)
    }

    func exportMeetingDocument(
        publishGist: Bool = false,
        isPublic: Bool = false
    ) -> ExportMeetingDocument {
        let publisher: (any MeetingDocumentPublishing)? = publishGist
            ? CLIGistDocumentPublisher(
                secrets: platform.secrets,
                gateway: URLSessionDataEgressGateway(receiptRecorder: store),
                isPublic: isPublic)
            : nil
        return ExportMeetingDocument(
            library: library,
            documents: CLIMeetingDocumentRenderer(),
            files: CLIFileAdapter(),
            publisher: publisher)
    }

    func publishMeetingActionItems(
        destination: CLIIssueDestination
    ) -> PublishMeetingActionItems {
        let gateway = URLSessionDataEgressGateway(receiptRecorder: store)
        return PublishMeetingActionItems(
            library: library,
            publisher: CLIMeetingActionItemPublisher(
                destination: destination,
                secrets: platform.secrets,
                gateway: gateway))
    }

    func refineMeeting(
        modelsDirectory: String?,
        language: String?,
        vocabulary: [String],
        clusteringThreshold: Float
    ) -> RefineMeetingUseCases {
        RefineMeetingUseCases(
            audioFiles: CLIRefineAudioFiles(),
            preferences: CLIRefineMeetingPreferences(snapshot: .init(
                transcriptLanguage: TranscriptLanguagePolicy(
                    persistedValue: language ?? "auto"),
                vocabulary: vocabulary)),
            processor: CLIRefineMeetingProcessor(
                modelsDirectory: modelsDirectory,
                clusteringThreshold: clusteringThreshold,
                voiceprintStore: platform.voiceprintStore),
            store: store,
            reader: store,
            companion: CLIDisabledRefineCompanion())
    }
}

enum CLIIssueDestination: Sendable {
    case github(repository: String)
    case linear(teamID: String)
}
