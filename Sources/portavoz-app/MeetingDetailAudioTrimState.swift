import ApplicationKit
import Foundation
import PortavozCore

/// When the detail can offer to cut a long silent tail, and what it reports.
@MainActor
enum MeetingDetailAudioTrimState {
    /// Length of the removable tail, or nil when the action should not be offered.
    static func trailingSilence(for state: MeetingDetailModel.State) -> TimeInterval? {
        guard !state.isTrimmingAudio, !state.isCompressingAudio,
              let detail = state.readModel, detail.meeting.lifecycleState == .ready,
              !detail.processingJobs.contains(where: { [.pending, .running].contains($0.state) }),
              let duration = state.playback?.session.duration,
              let cutoff = TrailingSilence.cutoff(segments: detail.segments, duration: duration)
        else { return nil }
        return duration - cutoff
    }

    static func trimRequest(for state: MeetingDetailModel.State) -> TrimMeetingAudioTailRequest? {
        guard trailingSilence(for: state) != nil,
              let detail = state.readModel, let relative = detail.meeting.audioDirectory,
              let duration = state.playback?.session.duration else { return nil }
        return TrimMeetingAudioTailRequest(
            meetingID: detail.meeting.id,
            relativeAudioDirectory: relative,
            transcriptRevision: detail.meeting.transcriptRevision,
            segments: detail.segments,
            duration: duration)
    }

    static func message(removed: TimeInterval) -> String {
        L10n.format("Removed %@ of silence.", formatted(removed))
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
