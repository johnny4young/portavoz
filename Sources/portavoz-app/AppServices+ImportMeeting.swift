import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import TranscriptionKit

extension AppServices {
    /// Imports external audio through the Band 2F application boundary while
    /// retaining the existing Library progress and navigation contract.
    func importMeeting(
        from source: URL,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> MeetingID {
        let request = ImportMeetingRequest(
            sourceURL: source,
            title: "Imported · " + source.deletingPathExtension().lastPathComponent
        ) { phase in
            let message = await Self.localizedImportProgress(phase)
            await progress(message)
        }
        let meetingID = try await importMeetingUseCase(request)
        libraryVersion += 1
        return meetingID
    }

    private var importMeetingUseCase: ImportMeeting {
        let localeLanguage = AppLanguage.current.locale.language.languageCode?.identifier
        let fallbackLanguage = LanguageCode(localeLanguage) ?? .english
        let sampledPreferences = ImportMeetingPreferencesSnapshot(
            transcriptLanguage: MeetingLanguagePreferences.transcript(),
            summaryLanguage: MeetingLanguagePreferences.summary(),
            summaryFallbackLanguage: fallbackLanguage,
            vocabulary: VocabularyPrompt.parse(
                UserDefaults.standard.string(forKey: "customVocabulary") ?? ""))
        let resolver = AppSummaryRegenerationProviderResolver(
            defaultEngine: summaryEngine,
            ollamaModel: ollamaModel,
            mlxModelDirectory: mlxDownloaded
                ? Self.modelDir(ModelCatalog.mlxQwen35)
                : nil,
            foundationModelsCapability: foundationModelsCapability)
        return ImportMeeting(
            audioFiles: AppImportMeetingAudioFiles(root: Self.audioRoot),
            preferences: AppImportMeetingPreferences(snapshot: sampledPreferences),
            processor: AppImportMeetingProcessor(services: self),
            store: store,
            summaryProviders: AppImportMeetingSummaryProviderResolver(
                resolver: resolver))
    }

    private static func localizedImportProgress(_ phase: ImportMeetingProgress) -> String {
        switch phase {
        case .preparingModels:
            L10n.text("Preparing models…")
        case .downloadingWhisper(let size, let percent):
            L10n.format(
                "Downloading Whisper (%@, one time only)… %d%%",
                size,
                percent)
        case .transcribing:
            L10n.text("Transcribing audio (Whisper)…")
        case .identifyingSpeakers:
            L10n.text("Identifying speakers…")
        case .generatingSummary:
            L10n.text("Generating summary…")
        }
    }
}

private struct AppImportMeetingPreferences: ImportMeetingPreferences {
    let snapshot: ImportMeetingPreferencesSnapshot

    func importMeetingPreferences() -> ImportMeetingPreferencesSnapshot {
        snapshot
    }
}

private struct AppImportMeetingAudioFiles: ImportMeetingAudioFiles {
    let root: URL

    func copySystemAudio(
        from source: URL,
        meetingID: MeetingID
    ) async throws -> ImportedMeetingAudio {
        let root = root
        return try await Task.detached(priority: .utility) {
            let relativeDirectory = "Audio/\(meetingID.rawValue.uuidString)"
            let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            let fileExtension = source.pathExtension.isEmpty
                ? "m4a"
                : source.pathExtension.lowercased()
            let destination = directory.appendingPathComponent("system.\(fileExtension)")
            let files = FileManager.default
            guard !files.fileExists(atPath: directory.path) else {
                throw AppImportMeetingError.audioDirectoryAlreadyExists(relativeDirectory)
            }
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try files.copyItem(at: source, to: destination)
                return ImportedMeetingAudio(
                    fileURL: destination,
                    relativeDirectory: relativeDirectory)
            } catch {
                try? files.removeItem(at: directory)
                throw error
            }
        }.value
    }

    func discardImportedAudio(_ audio: ImportedMeetingAudio) async throws {
        let directory = root.appendingPathComponent(
            audio.relativeDirectory,
            isDirectory: true)
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }.value
    }
}

@MainActor
private final class AppImportMeetingProcessor: ImportMeetingProcessor {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func prepareTranscriber(
        progress: @escaping ImportMeetingProgressHandler
    ) async throws {
        guard let services else { throw AppImportMeetingError.servicesUnavailable }
        _ = try await services.loadWhisperIfNeeded(
            progress: { _ in },
            downloadProgress: { size, percent in
                Task { await progress(.downloadingWhisper(size: size, percent: percent)) }
            })
    }

    func prepareDiarizer() async throws {
        guard let services else { throw AppImportMeetingError.servicesUnavailable }
        _ = try await services.loadDiarizerIfNeeded()
    }

    func transcribe(
        audio: ImportedMeetingAudio,
        meetingID: MeetingID,
        languageHint: String?,
        vocabulary: [String]
    ) async throws -> FileTranscription {
        guard let whisper = services?.whisper else {
            throw AppImportMeetingError.transcriberUnavailable
        }
        let hints = TranscriptionHints(
            language: languageHint,
            vocabulary: vocabulary,
            meetingID: meetingID)
        return try await whisper.transcribeFile(
            at: audio.fileURL,
            hints: hints,
            channel: .system)
    }

    func diarize(audio: ImportedMeetingAudio) async throws -> [SpeakerTurn] {
        guard let diarizer = services?.diarizer else {
            throw AppImportMeetingError.diarizerUnavailable
        }
        return try await diarizer.diarizeFile(at: audio.fileURL)
    }

    func scheduleIdleRelease() {
        services?.scheduleWhisperRelease()
        services?.scheduleRecordingEnginesRelease()
    }
}

private struct AppImportMeetingSummaryProviderResolver:
    ImportMeetingSummaryProviderResolver {
    let resolver: AppSummaryRegenerationProviderResolver

    func resolveImportMeetingSummaryProvider()
        -> ImportMeetingSummaryProviderResolution {
        switch resolver.resolve(override: nil) {
        case .available(let provider):
            return .available(AppImportMeetingSummaryProvider(provider: provider))
        case .unavailable:
            return .unavailable
        }
    }
}

private struct AppImportMeetingSummaryProvider: ImportMeetingSummaryProvider {
    let provider: any SummaryRegenerationProvider

    var providerID: String { provider.providerID }
    var modelID: String { provider.modelID }
    var modelRevision: String? { provider.modelRevision }

    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        try await provider.summarize(request)
    }
}

private enum AppImportMeetingError: Error {
    case audioDirectoryAlreadyExists(String)
    case servicesUnavailable
    case transcriberUnavailable
    case diarizerUnavailable
}
