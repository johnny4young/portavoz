import ApplicationKit

/// Keeps the player's voice strip between renders: it changes with the
/// published core or the prepared session, never with the 5 fps clock.
@MainActor
final class MeetingDetailPlayerStripCache {
    private var revision: Int?
    private weak var session: MeetingPlaybackSession?
    private var strip: MeetingPlayerStrip?

    func strip(for state: MeetingDetailModel.State) -> MeetingPlayerStrip? {
        guard let core = state.readModel?.core, let playback = state.playback else { return nil }
        if revision == state.revision, session === playback.session, let strip { return strip }
        let built = MeetingPlayerStrip(core: core, timeline: playback.session.timeline, waveform: playback.waveform)
        (revision, session, strip) = (state.revision, playback.session, built)
        return built
    }
}
