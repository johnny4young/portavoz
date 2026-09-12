import ApplicationKit
import DiarizationKit
import Foundation
import IntelligenceKit
import ModelStoreKit
import PortavozCore
import TranscriptionKit

extension AppServices: AudioImportQueueClient {
    func observeAudioImports(offset: Int) -> AsyncThrowingStream<AudioImportQueuePage, Error> {
        store.observeAudioImportQueue(offset: offset)
    }

    func admitAudioImports(_ urls: [URL]) async throws {
        guard !urls.isEmpty, urls.count <= 1_000 else { throw AudioImportQueueError.selectionLimit }
        let preferences = audioImportPreferences
        let files = audioImportFiles
        var inputs: [AudioImportRequest] = []
        for url in urls {
            try Task.checkCancellation()
            inputs.append(try await files.prepareSelection(
                url, meetingID: MeetingID(), title: url.deletingPathExtension().lastPathComponent,
                preferences: preferences))
        }
        _ = try await store.enqueueAudioImports(inputs)
    }

    func makeAudioImportWorker() -> ProcessAudioImports {
        let fixture = audioImportUITestFixture
        let summaries: any ImportMeetingSummaryProviderResolver = fixture
            ?? AppImportMeetingSummaryProviderResolver(resolver: summaryProviderResolver)
        return ProcessAudioImports(store: store, files: audioImportFiles, makeProcessor: { [weak self] in
            if let fixture { return fixture }
            return await AppImportMeetingProcessor(services: self)
        }, summaries: summaries, now: { Date().addingTimeInterval(fixture?.clockOffset ?? 0) })
    }

    func nextAudioImportWake() async throws -> Date? {
        try await store.nextScheduledProcessingDate(kinds: [.audioImport])
    }

    func cancelAudioImport(_ id: MeetingID) async throws {
        try await audioImportUITestFixture?.beforeCancellation()
        _ = try await store.cancelAudioImport(for: id)
    }
    func retryAudioImport(_ id: MeetingID) async throws { _ = try await store.retryAudioImport(for: id) }
    func audioImportWorkFinished() { requestSearchReconciliation() }

    private var audioImportPreferences: ImportMeetingPreferencesSnapshot {
        let localeLanguage = AppLanguage.current.locale.language.languageCode?.identifier
        return ImportMeetingPreferencesSnapshot(
            transcriptLanguage: MeetingLanguagePreferences.transcript(),
            summaryLanguage: MeetingLanguagePreferences.summary(),
            summaryFallbackLanguage: LanguageCode(localeLanguage) ?? .english,
            vocabulary: VocabularyPrompt.parse(UserDefaults.standard.string(forKey: "customVocabulary") ?? ""))
    }
}

@MainActor
private final class AppImportMeetingProcessor: ImportMeetingProcessor {
    private weak var services: AppServices?
    private var whisperRuntime: AppServices.WhisperRuntimeLease?
    private var diarizationRuntime: AppServices.DiarizationRuntimeLease?
    private var diarizer: PyannoteDiarizer?

    init(services: AppServices?) {
        self.services = services
    }

    func prepareTranscriber(
        progress: @escaping ImportMeetingProgressHandler
    ) async throws {
        guard let services else { throw AppImportMeetingError.servicesUnavailable }
        if whisperRuntime != nil { return }
        whisperRuntime = try await services.acquireWhisperRuntime(
            progress: { _ in },
            preparationProgress: { size, percent, isDownloading in
                Task {
                    await progress(.preparingWhisper(
                        size: size,
                        percent: percent,
                        isDownloading: isDownloading))
                }
            })
    }

    func prepareDiarizer() async throws {
        guard let services else { throw AppImportMeetingError.servicesUnavailable }
        if diarizationRuntime != nil { return }
        let runtime = try await services.acquireDiarizationRuntime()
        let voiceprint = await services.currentDiarizationVoiceprint()
        diarizer = services.makeDiarizer(
            from: runtime,
            voiceprint: voiceprint)
        diarizationRuntime = runtime
    }

    func transcribe(
        audio: ImportedMeetingAudio,
        meetingID: MeetingID,
        languageHint: String?,
        vocabulary: [String]
    ) async throws -> FileTranscription {
        guard let services, let whisper = whisperRuntime?.engine else {
            throw AppImportMeetingError.transcriberUnavailable
        }
        let hints = TranscriptionHints(
            language: languageHint,
            vocabulary: vocabulary,
            meetingID: meetingID)
        return try await services.workloadTelemetry.measure(
            ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: .qualityTranscription,
                operation: .execute)
        ) {
            try await whisper.transcribeFile(
                at: audio.fileURL,
                hints: hints,
                channel: .system)
        }
    }

    func diarize(audio: ImportedMeetingAudio) async throws -> [SpeakerTurn] {
        guard let services, let diarizer else {
            throw AppImportMeetingError.diarizerUnavailable
        }
        return try await services.workloadTelemetry.measure(
            ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: .speakerDiarization,
                operation: .execute)
        ) {
            try await diarizer.diarizeFile(at: audio.fileURL)
        }
    }

    func scheduleIdleRelease() {
        if let whisperRuntime {
            _ = services?.finishWhisperRuntime(whisperRuntime)
            self.whisperRuntime = nil
        }
        if let diarizationRuntime {
            _ = services?.finishDiarizationRuntime(diarizationRuntime)
            self.diarizationRuntime = nil
            diarizer = nil
        }
        services?.scheduleWhisperRelease()
        services?.scheduleRecordingEnginesRelease()
    }
}

private struct AppImportMeetingSummaryProviderResolver:
    ImportMeetingSummaryProviderResolver {
    let resolver: AppSummaryRegenerationProviderResolver

    func resolveImportMeetingSummaryProvider() async
        -> ImportMeetingSummaryProviderResolution {
        switch await resolver.resolve(override: nil) {
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
    case servicesUnavailable
    case transcriberUnavailable
    case diarizerUnavailable
}
