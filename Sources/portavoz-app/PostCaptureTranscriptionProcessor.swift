import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

/// Owns the durable first-pass recovery stage separately from the generic
/// worker loop. Audio/model fingerprint validation happens both before model
/// preparation and again in StorageKit's atomic artifact commit.
@MainActor
enum PostCaptureTranscriptionProcessor {
    static func process(
        _ job: ProcessingJob,
        owner: String,
        services: AppServices
    ) async throws {
        guard let detail = try await services.store.detail(job.meetingID) else {
            throw ProcessorError.meetingUnavailable
        }
        let assets = try await services.store.audioAssets(for: job.meetingID)
        guard let fingerprint = InitialTranscriptionOperationFingerprint.compute(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision,
            assets: assets)
        else { throw ProcessorError.inputNotReady }
        guard fingerprint == job.inputFingerprint else {
            throw ProcessorError.inputSuperseded
        }

        let transcriber = try await services.loadTranscriberIfNeeded()
        let segments = try await transcriptionSegments(
            assets: assets,
            meetingID: job.meetingID,
            transcriber: transcriber,
            scheduler: services.transcriptionScheduler)
        guard !segments.isEmpty else { throw ProcessorError.emptyTranscript }

        let attribution = SpeakerAttributor.attribute(
            segments: segments,
            turns: [],
            meetingID: job.meetingID)
        let language = SpokenLanguageDetector.homogeneousLanguage(
            in: attribution.segments)
        let voiceprint = await currentVoiceprint(services: services)
        guard let diarization = DiarizationOperationFingerprint.request(
            meetingID: job.meetingID,
            transcriptRevision: detail.meeting.transcriptRevision + 1,
            segments: attribution.segments,
            systemAsset: currentSystemCapture(in: assets),
            voiceprint: voiceprint)
        else { throw ProcessorError.inputNotReady }

        _ = try await services.store.completeTranscriptionJob(
            job.id,
            owner: owner,
            artifact: TranscriptionArtifact(
                meetingID: job.meetingID,
                inputFingerprint: fingerprint,
                sourceTranscriptRevision: detail.meeting.transcriptRevision,
                language: language,
                speakers: attribution.speakers,
                segments: attribution.segments),
            enqueue: [diarization])
        services.scheduleRecordingEnginesRelease()
    }

    private static func transcriptionSegments(
        assets: [AudioAsset],
        meetingID: MeetingID,
        transcriber: ParakeetEngine,
        scheduler: TranscriptionScheduler
    ) async throws -> [TranscriptSegment] {
        let current = currentCaptures(in: assets)
        let hints = TranscriptionHints(meetingID: meetingID)
        var systemSegments: [TranscriptSegment] = []
        if let system = current[.system] {
            systemSegments = try await transcribe(
                system,
                channel: .system,
                hints: hints,
                transcriber: transcriber,
                scheduler: scheduler)
        }

        var microphoneSegments: [TranscriptSegment] = []
        if let microphone = current[.microphone] {
            let raw = try await transcribe(
                microphone,
                channel: .microphone,
                hints: hints,
                transcriber: transcriber,
                scheduler: scheduler)
            let voiced = raw.filter {
                !TranscriptNoiseFilter.isLikelyNoise(
                    text: $0.text,
                    confidence: $0.confidence)
            }
            microphoneSegments = MicBleedFilter.filter(
                microphone: voiced,
                system: systemSegments)
        }
        return (systemSegments + microphoneSegments).sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func transcribe(
        _ asset: AudioAsset,
        channel: AudioChannel,
        hints: TranscriptionHints,
        transcriber: ParakeetEngine,
        scheduler: TranscriptionScheduler
    ) async throws -> [TranscriptSegment] {
        guard [.healthy, .clipped].contains(asset.healthStatus),
              (asset.durationSeconds ?? 0) > 1
        else { return [] }
        let url = RecordingsLocation.shared.resolve(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessorError.audioUnavailable
        }
        let result = try await scheduler.batch {
            try await transcriber.transcribeFile(
                at: url,
                hints: hints,
                channel: channel)
        }
        return result.segments
    }

    private static func currentCaptures(
        in assets: [AudioAsset]
    ) -> [AudioChannel: AudioAsset] {
        Dictionary(grouping: assets.filter {
            $0.role == .capture && $0.supersededAt == nil && $0.deletedAt == nil
        }, by: \.channel)
        .compactMapValues { candidates in
            candidates.max { $0.updatedAt < $1.updatedAt }
        }
    }

    private static func currentSystemCapture(in assets: [AudioAsset]) -> AudioAsset? {
        currentCaptures(in: assets)[.system]
    }

    private static func currentVoiceprint(services: AppServices) async -> Voiceprint? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("-seed-processing"),
              !arguments.contains("-seed-summary-retry")
        else { return nil }
        let store = services.voiceprintStore
        return await Task.detached(priority: .utility) {
            try? store.load()
        }.value
    }
}

private enum ProcessorError: LocalizedError {
    case audioUnavailable
    case emptyTranscript
    case inputNotReady
    case inputSuperseded
    case meetingUnavailable

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            "The captured audio is no longer available."
        case .emptyTranscript:
            "The recovered transcript is empty."
        case .inputNotReady:
            "The captured input is not ready for transcription."
        case .inputSuperseded:
            "The transcription input changed before processing completed."
        case .meetingUnavailable:
            "The meeting is no longer available."
        }
    }
}
