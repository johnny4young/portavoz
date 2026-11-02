import ApplicationKit
import AudioPlaybackKit
import Foundation
import StorageKit

extension AppServices {
    func canCompressMeetingDetailAudio(relativeAudioDirectory: String) async throws -> Bool {
        try await CheckMeetingAudioCompression(
            resolver: AppMeetingAudioChannelResolver(), admission: store).execute(relativeAudioDirectory)
    }

    func prepareMeetingDetailPlayback(
        _ request: PrepareMeetingPlaybackRequest
    ) async throws -> PreparedMeetingPlayback? {
        try await PrepareMeetingPlayback(
            resolver: AppMeetingAudioChannelResolver(),
            compressionAdmission: store,
            telemetry: workloadTelemetry).execute(request)
    }

    func compressMeetingDetailAudio(
        _ request: CompressMeetingAudioRequest
    ) async throws -> MeetingAudioCompressionResult {
        try await CompressMeetingAudio(
            resolver: AppMeetingAudioChannelResolver(),
            compressor: AppMeetingAudioCompressor(),
            compressionAdmission: store,
            telemetry: workloadTelemetry).execute(request)
    }

    func trimMeetingDetailAudioTail(
        _ request: TrimMeetingAudioTailRequest
    ) async throws -> TimeInterval {
        if ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
            try await UITestFeatureHandshake.pauseIfRequested(
                argument: "-simulate-audio-trim-handshake",
                readyEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_READY_PATH",
                continueEnvironmentKey: "PORTAVOZ_UI_TEST_AUDIO_TRIM_CONTINUE_PATH")
        }
        return try await TrimMeetingAudioTail(
            resolver: AppMeetingAudioChannelResolver(),
            trimmer: AudioFileTailTrimmer(),
            store: store).execute(request)
    }

    func exportMeetingDetailAudioClip(
        _ request: ExportMeetingAudioClipRequest
    ) async throws {
        try await ExportMeetingAudioClip(
            resolver: AppMeetingAudioChannelResolver(),
            telemetry: workloadTelemetry).execute(request)
    }
}

private struct AppMeetingAudioCompressor: MeetingAudioCompressing {
    func totalBytes(of files: [URL]) -> Int64 {
        AudioTranscoder.totalBytes(of: files)
    }

    func compress(_ sources: [URL]) async throws -> [URL] {
        try await AudioTranscoder.toAAC(sources: sources, deleteSources: true)
    }
}

private struct AppMeetingAudioChannelResolver: MeetingAudioChannelResolving {
    private let location: RecordingsLocation

    init(location: RecordingsLocation = RecordingsLocation.shared) {
        self.location = location
    }

    func resolve(relativeAudioDirectory: String) throws -> MeetingAudioChannels {
        let directory = location.resolve(relativeAudioDirectory)
        return MeetingAudioChannels(
            system: MeetingAudioLayout.channelFile(named: "system", in: directory),
            microphone: MeetingAudioLayout.channelFile(named: "microphone", in: directory))
    }
}
