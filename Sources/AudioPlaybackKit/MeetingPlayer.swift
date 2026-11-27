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
    /// True after AVPlayerItem enters `.failed` or fails playback to end.
    public private(set) var hasPlaybackFailed = false
    /// Counts playbacks that ran to the end and rewound.
    public private(set) var playedToEndCount = 0

    /// Clip in/out marks (M11). Set from the current playhead; a clip is
    /// valid once both exist and start < end.
    public private(set) var clipStart: TimeInterval?
    public private(set) var clipEnd: TimeInterval?

    /// Skip dead time during playback (M11), on by default. The caller
    /// supplies the ranges: transcript gaps, or waveform silence without one.
    public var skipSilence = true
    private var silentRanges: [ClosedRange<TimeInterval>] = []

    /// Play only one voice's turns; playback jumps over everything outside
    /// them exactly like silent gaps.
    public var playsFocusOnly = false
    private var outsideFocusRanges: [ClosedRange<TimeInterval>] = []

    /// Playback speed; pitch is preserved.
    public var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
        }
    }

    /// Removes the delayed copy of remote speech picked up by the microphone.
    /// The original flat channel mix remains one click away for unusual
    /// recordings whose transcript did not identify the local turns.
    public var clearPlayback = true {
        didSet { player.currentItem?.audioMix = clearPlayback ? cleanAudioMix : nil }
    }
    public let canClearPlayback: Bool

    /// The channel files this player mixed — the clip exporter trims these.
    public let channelFiles: [URL]

    private let player: AVPlayer
    private let cleanAudioMix: AVAudioMix?
    private let observerCleanup: PlayerObserverCleanup
    private var isSeekInFlight = false
    private var pendingSeekTarget: TimeInterval?
    private var isInvalidated = false

    private init(
        item: AVPlayerItem,
        duration: TimeInterval,
        channelFiles: [URL],
        cleanAudioMix: AVAudioMix?
    ) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.cleanAudioMix = cleanAudioMix
        self.canClearPlayback = cleanAudioMix != nil
        self.duration = duration
        self.channelFiles = channelFiles
        self.observerCleanup = PlayerObserverCleanup(player: player)
        item.audioMix = cleanAudioMix
        installObservers(item: item)
    }

    deinit {
        observerCleanup.teardown()
    }

    private func installObservers(item: AVPlayerItem) {
        // 5 fps: smooth enough for a highlight + scrubber, cheap enough not
        // to churn a long transcript's rows.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        let timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A queued seek has not reached AVPlayer yet; its stale time must not rewind the playhead.
                guard self.pendingSeekTarget == nil else { return }
                self.currentTime = min(time.seconds, self.duration)
                guard self.isPlaying else { return }
                if let target = Self.skipTarget(
                    at: self.currentTime,
                    duration: self.duration,
                    skipSilence: self.skipSilence,
                    silentRanges: self.silentRanges,
                    playsFocusOnly: self.playsFocusOnly,
                    outsideFocusRanges: self.outsideFocusRanges
                ) {
                    self.seek(to: target)
                }
            }
        }
        // Playing to the end stops and rewinds, so the transport button
        // flips back to "play" instead of pretending it's still going.
        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.playedToEndCount += 1
                self.seek(to: 0)
            }
        }
        let failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackFailure()
            }
        }
        let statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure()
            }
        }
        let timeControlObservation = player.observe(
            \.timeControlStatus, options: [.old, .new]
        ) { [weak self] observed, change in
            guard change.oldValue != .paused,
                  change.newValue == .paused,
                  observed.rate == 0
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.rate == 0 else { return }
                self.isPlaying = false
            }
        }
        observerCleanup.install(
            timeObserver: timeObserver,
            endObserver: endObserver,
            failedObserver: failedObserver,
            statusObservation: statusObservation,
            timeControlObservation: timeControlObservation)
    }

    /// Builds a player mixing every existing channel file. Returns nil when
    /// none is readable (e.g. audio deleted by the retention policy).
    public static func make(channelFiles: [URL]) async -> MeetingPlayer? {
        let existing = channelFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        guard let mixed = await MeetingAudioComposition.make(channelFiles: existing) else {
            return nil
        }

        return MeetingPlayer(
            item: AVPlayerItem(asset: mixed.composition),
            duration: mixed.duration.seconds,
            channelFiles: existing,
            cleanAudioMix: nil)
    }

    /// Builds the default clear meeting mix. Direct system audio stays intact;
    /// the microphone is full-volume only around transcript-confirmed local
    /// turns and quiet elsewhere so speaker bleed does not become an echo.
    public static func make(
        systemFile: URL?,
        microphoneFile: URL?,
        microphoneAudibleRanges: [ClosedRange<TimeInterval>]
    ) async -> MeetingPlayer? {
        guard let mixed = await MeetingAudioComposition.make(
            systemFile: systemFile,
            microphoneFile: microphoneFile,
            microphoneAudibleRanges: microphoneAudibleRanges)
        else { return nil }
        return MeetingPlayer(
            item: AVPlayerItem(asset: mixed.composition),
            duration: mixed.duration.seconds,
            channelFiles: [systemFile, microphoneFile].compactMap { $0 },
            cleanAudioMix: mixed.cleanAudioMix)
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
        silentRanges = Self.normalizeRanges(ranges)
    }

    /// Everything outside the focused voice, merged and sorted by the caller.
    public func setOutsideFocusRanges(_ ranges: [ClosedRange<TimeInterval>]) {
        outsideFocusRanges = Self.normalizeRanges(ranges)
    }

    public func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    public func play() {
        guard !isInvalidated else { return }
        guard player.currentItem?.status != .failed else {
            handlePlaybackFailure()
            return
        }
        hasPlaybackFailed = false
        // Restart from the top if we're parked at the end.
        if currentTime >= duration - 0.05 { restartFromTop() }
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
        guard !isInvalidated else { return }
        // Coalesce rapid scrub drags so AVPlayer finishes one exact seek before starting the next.
        if isSeekInFlight {
            pendingSeekTarget = clamped
            return
        }
        startSeek(to: clamped)
    }

    /// Releases the AVFoundation observers. Also runs defensively in `deinit`.
    public func invalidate() {
        isInvalidated = true
        pendingSeekTarget = nil
        isSeekInFlight = false
        pause()
        observerCleanup.teardown()
    }

    private func handlePlaybackFailure() {
        player.pause()
        isPlaying = false
        hasPlaybackFailed = true
    }

    /// Bypasses coalescing: a queued restart behind a seek to the end would let
    /// AVPlayer play out the end and park paused at 0.
    private func restartFromTop() {
        currentTime = 0
        pendingSeekTarget = nil
        startSeek(to: 0)
    }

    private func startSeek(to seconds: TimeInterval) {
        isSeekInFlight = true
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completeSeek()
            }
        }
    }

    private func completeSeek() {
        isSeekInFlight = false
        guard !isInvalidated, let next = pendingSeekTarget else { return }
        pendingSeekTarget = nil
        startSeek(to: next)
    }

    /// Sorts and merges overlapping ranges so lookup runs in O(log n).
    nonisolated static func normalizeRanges(
        _ ranges: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        merged.reserveCapacity(sorted.count)
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    nonisolated static func containingRange(
        at time: TimeInterval,
        in sortedRanges: [ClosedRange<TimeInterval>]
    ) -> ClosedRange<TimeInterval>? {
        var low = 0
        var high = sortedRanges.count
        while low < high {
            let mid = low + (high - low) / 2
            let range = sortedRanges[mid]
            if time < range.lowerBound {
                high = mid
            } else if time > range.upperBound {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    /// Resolves combined silence and focus-voice skips in one hop so landing
    /// from a silent gap inside an excluded turn never plays a 200 ms blip.
    nonisolated static func skipTarget(
        at time: TimeInterval,
        duration: TimeInterval,
        skipSilence: Bool,
        silentRanges: [ClosedRange<TimeInterval>],
        playsFocusOnly: Bool,
        outsideFocusRanges: [ClosedRange<TimeInterval>]
    ) -> TimeInterval? {
        var candidate = time
        var jumped = false
        let maxHops = silentRanges.count + outsideFocusRanges.count + 2
        for _ in 0..<maxHops {
            if skipSilence,
               let gap = containingRange(at: candidate, in: silentRanges),
               candidate < gap.upperBound - 0.3 {
                let next = min(duration, gap.upperBound - 0.2)
                if next > candidate + 0.001 {
                    candidate = next
                    jumped = true
                    continue
                }
            }
            if playsFocusOnly,
               let gap = containingRange(at: candidate, in: outsideFocusRanges),
               candidate < gap.upperBound - 0.3 {
                let next = min(duration, gap.upperBound - 0.05)
                if next > candidate + 0.001 {
                    candidate = next
                    jumped = true
                    continue
                }
            }
            break
        }
        return jumped ? candidate : nil
    }
}

private final class PlayerObserverCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
    }

    func install(
        timeObserver: Any,
        endObserver: NSObjectProtocol,
        failedObserver: NSObjectProtocol,
        statusObservation: NSKeyValueObservation,
        timeControlObservation: NSKeyValueObservation
    ) {
        lock.lock()
        self.timeObserver = timeObserver
        self.endObserver = endObserver
        self.failedObserver = failedObserver
        self.statusObservation = statusObservation
        self.timeControlObservation = timeControlObservation
        lock.unlock()
    }

    func teardown() {
        lock.lock()
        let timeObserver = self.timeObserver
        let endObserver = self.endObserver
        let failedObserver = self.failedObserver
        let statusObservation = self.statusObservation
        let timeControlObservation = self.timeControlObservation
        self.timeObserver = nil
        self.endObserver = nil
        self.failedObserver = nil
        self.statusObservation = nil
        self.timeControlObservation = nil
        lock.unlock()

        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
    }
}
