import ApplicationKit
import AudioCaptureKit
import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import StorageKit
import TranscriptionKit

extension AppServices {
    /// Refine draft/apply workflows composed from the shared local engines and
    /// private platform adapters.
    var refineMeeting: RefineMeetingUseCases {
        RefineMeetingUseCases(
            audioFiles: AppRefineMeetingAudioFiles(),
            preferences: AppRefineMeetingPreferences(
                snapshot: RefineMeetingPreferencesSnapshot(
                    transcriptLanguage: MeetingLanguagePreferences.transcript(),
                    vocabulary: VocabularyPrompt.parse(
                        UserDefaults.standard.string(forKey: "customVocabulary") ?? ""))),
            processor: AppRefineMeetingProcessor(services: self),
            store: store,
            companion: AppRefineMeetingCompanion())
    }
}

private struct AppRefineMeetingAudioFiles: RefineMeetingAudioFiles {
    func resolveRefineAudio(_ relativeDirectory: String) async -> RefineMeetingAudio {
        let base = RecordingsLocation.shared.resolve(relativeDirectory)
        return await Task.detached(priority: .utility) {
            let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base)
            let microphoneURL = MeetingAudioLayout.channelFile(named: "microphone", in: base)
            return RefineMeetingAudio(
                system: systemURL.map {
                    RefineMeetingAudioChannel(
                        fileURL: $0,
                        isSilent: AudioSilence.fileIsSilent(at: $0))
                },
                microphone: microphoneURL.map {
                    RefineMeetingAudioChannel(
                        fileURL: $0,
                        isSilent: AudioSilence.fileIsSilent(at: $0))
                })
        }.value
    }
}

private struct AppRefineMeetingPreferences: RefineMeetingPreferences {
    let snapshot: RefineMeetingPreferencesSnapshot

    func refineMeetingPreferences() -> RefineMeetingPreferencesSnapshot { snapshot }
}

@MainActor
private final class AppRefineMeetingProcessor: RefineMeetingProcessor {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func prepare(progress: @escaping RefineMeetingProgressHandler) async throws {
        guard let services else { throw AppRefineMeetingError.servicesUnavailable }
        _ = try await services.loadWhisperIfNeeded(
            progress: { _ in },
            downloadProgress: { size, percent in
                Task { await progress(.downloadingWhisper(size: size, percent: percent)) }
            })
        try await services.loadEnginesIfNeeded()
    }

    func transcribe(
        fileURL: URL,
        hints: TranscriptionHints,
        channel: AudioChannel
    ) async throws -> FileTranscription {
        guard let whisper = services?.whisper else {
            throw AppRefineMeetingError.transcriberUnavailable
        }
        return try await whisper.transcribeFile(
            at: fileURL,
            hints: hints,
            channel: channel)
    }

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        guard let diarizer = services?.diarizer else {
            throw AppRefineMeetingError.diarizerUnavailable
        }
        return try await diarizer.diarizeFile(at: fileURL)
    }

    func scheduleIdleRelease() {
        services?.scheduleWhisperRelease()
        services?.scheduleRecordingEnginesRelease()
    }
}

@MainActor
private final class AppRefineMeetingCompanion: RefineMeetingCompanion {
    func isRefreshAvailable() -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return UserDefaults.standard.bool(forKey: "companionEnabled")
            && FoundationModelSummaryProvider.unavailabilityReason() == nil
    }

    func refresh(
        segments: [TranscriptSegment],
        meetingID: MeetingID
    ) async -> RefineMeetingCompanionRefresh {
        guard #available(macOS 26.0, *) else {
            return RefineMeetingCompanionRefresh(cards: [], completed: false)
        }
        let result = await CompanionRefresh.regenerate(
            from: segments,
            meetingID: meetingID)
        return RefineMeetingCompanionRefresh(
            cards: result.cards,
            completed: result.completed)
    }
}

private enum AppRefineMeetingError: Error {
    case servicesUnavailable
    case transcriberUnavailable
    case diarizerUnavailable
}
