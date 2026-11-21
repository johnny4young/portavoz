import ApplicationKit
import Foundation
import PortavozCore

/// Prepares playback at the position where listening stopped and saves each
/// checkpoint. Both are optional: a failed read or write leaves playback as is.
@MainActor
final class MeetingDetailPlaybackResume {
    /// The last position saved here, ahead of a write still in flight.
    private var latest: MeetingPlaybackPosition?
    /// Saves run one after another so the last checkpoint is the one stored.
    private var pendingSave: Task<Void, Never>?

    /// The route applies its own pending seek afterwards, so that seek still wins.
    func prepare(
        _ request: PrepareMeetingPlaybackRequest,
        meetingID: MeetingID,
        client: any MeetingDetailModelClient
    ) async throws -> PreparedMeetingPlayback? {
        var saved = latest
        if saved == nil { saved = try? await client.meetingDetailPlaybackPosition(meetingID) }
        guard let prepared = try await client.prepareMeetingDetailPlayback(request) else { return nil }
        let session = prepared.session
        if let seconds = saved?.resumeTime(duration: session.duration) {
            session.seek(to: seconds)
        }
        session.onCheckpoint = { [weak self] checkpoint in
            let position = MeetingPlaybackPosition(
                meetingID: meetingID, seconds: checkpoint.seconds,
                isHeard: checkpoint.reachedEnd, updatedAt: Date())
            guard let self else { return }
            latest = position
            let previous = pendingSave
            pendingSave = Task {
                await previous?.value
                try? await client.saveMeetingDetailPlaybackPosition(position)
            }
        }
        return prepared
    }
}
