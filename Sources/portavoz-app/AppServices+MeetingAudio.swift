import ApplicationKit
import AudioPlaybackKit
import Foundation
import StorageKit

extension AppServices {
    func prepareMeetingDetailPlayback(
        _ request: PrepareMeetingPlaybackRequest
    ) async throws -> PreparedMeetingPlayback? {
        try await PrepareMeetingPlayback(
            resolver: AppMeetingAudioChannelResolver()).execute(request)
    }

    func compressMeetingDetailAudio(
        _ request: CompressMeetingAudioRequest
    ) async throws -> MeetingAudioCompressionResult {
        try await CompressMeetingAudio(
            resolver: AppMeetingAudioChannelResolver(),
            compressor: AppMeetingAudioCompressor()).execute(request)
    }

    func exportMeetingDetailAudioClip(
        _ request: ExportMeetingAudioClipRequest
    ) async throws {
        try await ExportMeetingAudioClip(
            resolver: AppMeetingAudioChannelResolver()).execute(request)
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
