import ApplicationKit
import AudioPlaybackKit
import Foundation
import Observation
import PortavozCore

/// View-lifetime coordination shared by transcript evidence and playback.
///
/// The state contains no model, service, storage, or audio-construction
/// dependency. It maps accepted transcript rows to an already prepared player
/// and retains pending seeks until that player becomes available.
@MainActor
@Observable
final class MeetingDetailPlaybackNavigation {
    private var transcript = MeetingTranscriptNavigationState()
    private var didRunPerformanceSeek = false

    var focusedRowID: UUID? { transcript.focusedRowID }

    func focusEvidence(
        _ segment: TranscriptSegment,
        content: MeetingTranscriptContent,
        player: MeetingPlaybackSession?
    ) {
        transcript.reveal(
            sourceSegmentID: segment.id,
            at: segment.startTime,
            in: content)
        applyPendingSeek(to: player)
    }

    @discardableResult
    func requestSeek(
        to timestamp: TimeInterval,
        content: MeetingTranscriptContent,
        player: MeetingPlaybackSession?
    ) -> Bool {
        transcript.requestSeek(to: timestamp, in: content)
        return applyPendingSeek(to: player)
    }

    func seekAndPlay(
        _ timestamp: TimeInterval,
        content: MeetingTranscriptContent,
        player: MeetingPlaybackSession?
    ) {
        guard let player else { return }
        transcript.requestSeek(to: timestamp, in: content)
        guard let target = transcript.consumePendingSeek() else { return }
        player.seek(to: target)
        player.play()
    }

    @discardableResult
    func applyPendingSeek(to player: MeetingPlaybackSession?) -> Bool {
        guard let player, let seconds = transcript.consumePendingSeek() else { return false }
        player.seek(to: seconds)
        return true
    }

    func runPerformanceSeekIfRequested(
        profile: MeetingDetailPerformanceProfile,
        player: MeetingPlaybackSession?
    ) {
        guard MeetingDetailPerformanceTrace.isEnabled,
              profile.shouldExercisePlaybackSeek,
              !didRunPerformanceSeek,
              let player
        else { return }
        didRunPerformanceSeek = true
        Task { @MainActor [player] in
            for fraction in [0.2, 0.8, 0.4, 0.6, 0.25] {
                MeetingDetailPerformanceTrace.measurePlaybackSeek {
                    player.seek(to: player.duration * fraction)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
