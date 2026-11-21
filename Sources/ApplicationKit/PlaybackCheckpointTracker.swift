import Foundation

/// A listening position worth keeping. `reachedEnd` marks playback that ran to
/// the end, after which the player rests at the start.
public struct PlaybackCheckpoint: Equatable, Sendable {
    public let seconds: TimeInterval
    public let reachedEnd: Bool

    public init(seconds: TimeInterval, reachedEnd: Bool) {
        self.seconds = seconds
        self.reachedEnd = reachedEnd
    }
}

/// Decides when the playhead is worth saving: on pause, once a seek settles,
/// periodically while playing and on reaching the end. Nothing counts until
/// playback starts, so opening or navigating a meeting never records listening.
struct PlaybackCheckpointTracker {
    static let periodicInterval: TimeInterval = 10
    static let seekSettleInterval: TimeInterval = 1

    private(set) var hasPlayed = false
    private var wasPlaying = false
    private var lastCheckpointAt: TimeInterval = 0
    private var seekAt: TimeInterval?

    mutating func didPlay(at now: TimeInterval) {
        if !hasPlayed { lastCheckpointAt = now }
        hasPlayed = true
    }

    mutating func didSeek(at now: TimeInterval) {
        seekAt = now
    }

    /// Whether the transport state observed at `now` should be saved.
    mutating func shouldCheckpoint(isPlaying: Bool, reachedEnd: Bool, at now: TimeInterval) -> Bool {
        defer { wasPlaying = isPlaying }
        guard hasPlayed else {
            seekAt = nil
            return false
        }
        let paused = wasPlaying && !isPlaying
        let settled = seekAt.map { now - $0 >= Self.seekSettleInterval } ?? false
        let due = isPlaying && now - lastCheckpointAt >= Self.periodicInterval
        guard reachedEnd || paused || settled || due else { return false }
        seekAt = nil
        lastCheckpointAt = now
        return true
    }
}
