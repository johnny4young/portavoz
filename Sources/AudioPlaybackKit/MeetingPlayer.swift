import AVFoundation
import Foundation
import Observation

/// Synchronized playback of a meeting (M11/D27). A meeting is stored as
/// separate per-channel files (microphone + system); this mixes them into
/// ONE timeline via an `AVMutableComposition`, so there is a single
/// current-time to drive the transcript highlight and a single scrubber.
///
/// `@MainActor` + `@Observable`: the periodic time observer publishes
/// `currentTime` on the main actor, which SwiftUI reads directly.
@MainActor
@Observable
public final class MeetingPlayer {
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false

    /// Clip in/out marks (M11). Set from the current playhead; a clip is
    /// valid once both exist and start < end.
    public private(set) var clipStart: TimeInterval?
    public private(set) var clipEnd: TimeInterval?

    /// Skip silent gaps during playback (M11). The silent ranges come from
    /// the waveform.
    public var skipSilence = false
    private var silentRanges: [ClosedRange<TimeInterval>] = []

    /// The channel files this player mixed — the clip exporter trims these.
    public let channelFiles: [URL]

    private let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init(item: AVPlayerItem, duration: TimeInterval, channelFiles: [URL]) {
        self.player = AVPlayer(playerItem: item)
        self.duration = duration
        self.channelFiles = channelFiles

        // 5 fps: smooth enough for a highlight + scrubber, cheap enough not
        // to churn a long transcript's rows.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = min(time.seconds, self.duration)
                // Jump over a silent gap when asked (M11), leaving a small
                // margin at its end so speech isn't clipped.
                if self.skipSilence, self.isPlaying,
                    let gap = self.silentRanges.first(where: {
                        $0.contains(self.currentTime) && self.currentTime < $0.upperBound - 0.3
                    }) {
                    self.seek(to: gap.upperBound - 0.2)
                }
            }
        }
        // Playing to the end stops and rewinds, so the transport button
        // flips back to "play" instead of pretending it's still going.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }

    /// Builds a player mixing every existing channel file. Returns nil when
    /// none is readable (e.g. audio deleted by the retention policy).
    public static func make(channelFiles: [URL]) async -> MeetingPlayer? {
        let existing = channelFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero
        for url in existing {
            let asset = AVURLAsset(url: url)
            guard
                let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let assetDuration = try? await asset.load(.duration),
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? track.insertTimeRange(
                CMTimeRange(start: .zero, duration: assetDuration), of: assetTrack, at: .zero)
            maxDuration = CMTimeMaximum(maxDuration, assetDuration)
        }
        guard maxDuration > .zero else { return nil }

        return MeetingPlayer(
            item: AVPlayerItem(asset: composition), duration: maxDuration.seconds,
            channelFiles: existing)
    }

    // MARK: - Clip marks (M11)

    /// The valid clip range, or nil until both marks exist with start < end.
    public var clipRange: ClosedRange<TimeInterval>? {
        guard let start = clipStart, let end = clipEnd, end > start else { return nil }
        return start...end
    }

    public func markClipStart() {
        clipStart = currentTime
        if let end = clipEnd, end <= currentTime { clipEnd = nil }
    }

    public func markClipEnd() {
        clipEnd = currentTime
        if let start = clipStart, start >= currentTime { clipStart = nil }
    }

    public func clearClip() {
        clipStart = nil
        clipEnd = nil
    }

    public func setSilentRanges(_ ranges: [ClosedRange<TimeInterval>]) {
        silentRanges = ranges
    }

    public func play() {
        // Restart from the top if we're parked at the end.
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Releases the AVFoundation observers. Call from the view's
    /// `onDisappear`; AVPlayer leaks its periodic observer otherwise.
    public func invalidate() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
