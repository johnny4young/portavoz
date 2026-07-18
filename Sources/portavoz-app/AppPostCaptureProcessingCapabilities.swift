import ApplicationKit
import DiarizationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import TranscriptionKit

/// Concrete model, filesystem, preference, and automation adapter for the
/// application-owned durable post-capture workflow.
@MainActor
final class AppPostCaptureProcessingCapabilities:
    PostCaptureAudioProcessing,
    PostCaptureSummaryConfiguration,
    PostCaptureCompletionActions {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func transcribePostCaptureAudio(
        _ asset: AudioAsset,
        channel: AudioChannel,
        hints: TranscriptionHints
    ) async throws -> FileTranscription {
        guard let services else { throw CancellationError() }
        let url = RecordingsLocation.shared.resolve(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PostCaptureProcessingCapabilityError.audioUnavailable
        }
        let transcriber = try await services.loadTranscriberIfNeeded()
        return try await services.transcriptionScheduler.batch {
            try await transcriber.transcribeFile(
                at: url,
                hints: hints,
                channel: channel)
        }
    }

    func currentPostCaptureVoiceprint() async -> Voiceprint? {
        guard !Self.isSafeProcessingFixture, let services else { return nil }
        let store = services.voiceprintStore
        return await Task.detached(priority: .utility) {
            try? store.load()
        }.value
    }

    func diarizePostCaptureAudio(_ asset: AudioAsset) async throws -> [SpeakerTurn] {
        guard let services else { throw CancellationError() }
        let url = RecordingsLocation.shared.resolve(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PostCaptureProcessingCapabilityError.audioUnavailable
        }

        // Attribution remains degradable: unavailable model preparation or
        // inference yields an unattributed system channel, but missing durable
        // audio remains a workflow failure.
        guard let diarizer = try? await services.loadDiarizerIfNeeded() else { return [] }
        return (try? await diarizer.diarizeFile(at: url)) ?? []
    }

    func postCaptureSummaryProvider() -> PostCaptureSummaryProviderSelection? {
        services?.processingPostCaptureSummaryProviderSelection()
    }

    func postCaptureSummaryPreferences(
        spokenLanguage: String?
    ) -> PostCaptureSummaryPreferences {
        PostCaptureSummaryPreferences(
            outputLanguage: MeetingLanguagePreferences.resolvedSummaryLanguage(
                spokenLanguage: spokenLanguage).identifier,
            vocabulary: VocabularyPrompt.parse(
                UserDefaults.standard.string(forKey: "customVocabulary") ?? ""))
    }

    func runPostMeetingAction(for meetingID: MeetingID) async {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store"),
              let services
        else { return }
        do {
            guard let detail = try await services.store.detail(meetingID) else { return }
            let summary = try await services.store.summary(meetingID)?.draft
            PostMeetingShortcut.runIfConfigured(markdown: MeetingExporter.markdown(
                meeting: detail.meeting,
                speakers: detail.speakers,
                segments: detail.segments,
                summary: summary))
        } catch {
            PostCaptureProcessingCoordinator.logPostMeetingActionFailure(error)
        }
    }

    func schedulePostCaptureIdleRelease() {
        services?.scheduleRecordingEnginesRelease()
    }

    private static var isSafeProcessingFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-seed-processing")
            && arguments.contains("-use-temp-store")
    }
}
