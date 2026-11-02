import ApplicationKit
import Foundation

/// Permission reads have their own lifetime; they never replace the player.
@MainActor
final class MeetingDetailAudioCompressionState {
    private var generation = 0

    func invalidate() { generation += 1 }

    func refresh(state: MeetingDetailModel.State, client: any MeetingDetailModelClient)
        async -> (playback: PreparedMeetingPlayback, directory: String)? {
        generation += 1
        let request = generation
        guard let prepared = state.playback, let directory = state.readModel?.meeting.audioDirectory else { return nil }
        let allowed = (try? await client.canCompressMeetingDetailAudio(relativeAudioDirectory: directory)) == true
        guard !Task.isCancelled, request == generation else { return nil }
        let playback = PreparedMeetingPlayback(
            session: prepared.session, waveform: prepared.waveform, canCompressAudio: allowed)
        return (playback, directory)
    }

    static func requiresRefresh(_ update: MeetingReviewUpdate) -> Bool {
        switch update {
        case .core, .processingJobs, .failed(.core), .failed(.processing): true
        default: false
        }
    }

    static func canCompress(_ state: MeetingDetailModel.State) -> Bool {
        !state.isCompressingAudio && !state.isTrimmingAudio && state.playback?.canCompressAudio == true
    }

    static func compressionRequest(for state: MeetingDetailModel.State) -> CompressMeetingAudioRequest? {
        guard canCompress(state), let relative = state.readModel?.meeting.audioDirectory else { return nil }
        return CompressMeetingAudioRequest(relativeAudioDirectory: relative)
    }

    static func isCurrent(
        _ refreshed: (playback: PreparedMeetingPlayback, directory: String), state: MeetingDetailModel.State
    ) -> Bool {
        state.readModel?.meeting.audioDirectory == refreshed.directory
            && state.playback?.session === refreshed.playback.session
    }

    static func message(bytesFreed: Int64) -> String {
        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        return L10n.format("Audio compressed — %@ freed.", freed)
    }
}
