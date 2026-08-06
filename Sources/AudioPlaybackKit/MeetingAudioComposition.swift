import AVFoundation
import Foundation

/// A channel-aware meeting composition. System audio is the clean remote
/// source; the microphone is opened only around transcript-confirmed local
/// turns so loudspeaker bleed cannot play a delayed copy of remote speech.
struct MeetingAudioComposition {
    let composition: AVMutableComposition
    let duration: CMTime
    let cleanAudioMix: AVAudioMix?

    static func make(
        systemFile: URL?,
        microphoneFile: URL?,
        microphoneAudibleRanges: [ClosedRange<TimeInterval>]
    ) async -> MeetingAudioComposition? {
        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero
        var hasSystemTrack = false
        var microphoneTrack: AVMutableCompositionTrack?

        if let result = await add(file: systemFile, to: composition) {
            hasSystemTrack = true
            maxDuration = CMTimeMaximum(maxDuration, result.duration)
        }
        if let result = await add(file: microphoneFile, to: composition) {
            microphoneTrack = result.track
            maxDuration = CMTimeMaximum(maxDuration, result.duration)
        }
        guard maxDuration > .zero else { return nil }

        let cleanAudioMix = hasSystemTrack ? microphoneTrack.flatMap { track in
            cleanMix(
                for: track,
                duration: maxDuration.seconds,
                audibleRanges: microphoneAudibleRanges)
        } : nil
        return MeetingAudioComposition(
            composition: composition,
            duration: maxDuration,
            cleanAudioMix: cleanAudioMix)
    }

    static func make(channelFiles: [URL]) async -> MeetingAudioComposition? {
        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero
        for file in channelFiles {
            if let result = await add(file: file, to: composition) {
                maxDuration = CMTimeMaximum(maxDuration, result.duration)
            }
        }
        guard maxDuration > .zero else { return nil }
        return MeetingAudioComposition(
            composition: composition,
            duration: maxDuration,
            cleanAudioMix: nil)
    }

    private static func add(
        file: URL?,
        to composition: AVMutableComposition
    ) async -> (track: AVMutableCompositionTrack, duration: CMTime)? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        let asset = AVURLAsset(url: file)
        guard
            let source = try? await asset.loadTracks(withMediaType: .audio).first,
            let duration = try? await asset.load(.duration),
            duration > .zero,
            let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        do {
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: .zero)
            return (track, duration)
        } catch {
            composition.removeTrack(track)
            return nil
        }
    }

    /// Mutes the microphone outside local turns because the system channel is
    /// already the clean remote source. Short ramps avoid clicks at speech
    /// boundaries. Mic-only recordings never receive this mix.
    ///
    /// The schedule is computed as pure policy and replayed here unchanged.
    /// `AVMutableAudioMixInputParameters` raises an Objective-C exception —
    /// which Swift cannot catch, so the process aborts — when volume events
    /// arrive out of order or with overlapping ramps, so an unordered schedule
    /// fails closed to no mix instead of reaching AVFoundation.
    private static func cleanMix(
        for microphoneTrack: AVCompositionTrack,
        duration: TimeInterval,
        audibleRanges: [ClosedRange<TimeInterval>]
    ) -> AVAudioMix? {
        let schedule = CleanPlaybackPolicy.volumeSchedule(
            audibleRanges: audibleRanges,
            duration: duration)
        guard !schedule.isEmpty,
              CleanPlaybackPolicy.isStrictlyOrdered(schedule)
        else { return nil }

        let parameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
        for event in schedule {
            switch event {
            case let .level(volume, time):
                parameters.setVolume(volume, at: Self.time(time))
            case let .ramp(from, to, start, end):
                parameters.setVolumeRamp(
                    fromStartVolume: from,
                    toEndVolume: to,
                    timeRange: CMTimeRange(
                        start: Self.time(start),
                        end: Self.time(end)))
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

/// One microphone volume instruction on the playback timeline. The schedule is
/// the complete contract between clear-playback policy and AVFoundation.
public enum CleanPlaybackVolumeEvent: Equatable, Sendable {
    case level(volume: Float, at: TimeInterval)
    case ramp(
        from: Float,
        to: Float,
        start: TimeInterval,
        end: TimeInterval)

    /// When the event begins, and when the timeline is free again.
    public var start: TimeInterval {
        switch self {
        case let .level(_, time): time
        case let .ramp(_, _, start, _): start
        }
    }

    public var end: TimeInterval {
        switch self {
        case let .level(_, time): time
        case let .ramp(_, _, _, end): end
        }
    }
}

/// Pure policy behind clear playback, separated from AVFoundation so boundary
/// and failure behavior stay deterministic in unit tests.
public enum CleanPlaybackPolicy {
    public static let backgroundMicrophoneGain: Float = 0
    public static let attack: TimeInterval = 0.06
    public static let release: TimeInterval = 0.12

    /// Two local turns can be ducked apart only when the release ramp of the
    /// earlier one finishes before the attack ramp of the later one has to
    /// start — otherwise the ramps overlap. Ducking for under `attack +
    /// release` is inaudible anyway, so such turns become one range.
    ///
    /// This compares the ramp boundaries the schedule actually emits instead
    /// of the gap against a separation constant, so no rounding at the
    /// boundary can let an overlapping pair through.
    public static func canDuckBetween(
        earlierEnd: TimeInterval,
        laterStart: TimeInterval
    ) -> Bool {
        earlierEnd + release <= laterStart - attack
    }

    public static func audibleRanges(
        _ ranges: [ClosedRange<TimeInterval>],
        duration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0 else { return [] }
        let clamped = ranges.compactMap { range -> ClosedRange<TimeInterval>? in
            let lower = min(duration, max(0, range.lowerBound))
            let upper = min(duration, max(0, range.upperBound))
            return lower < upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<TimeInterval>] = []
        for range in clamped {
            if let last = merged.last,
               !canDuckBetween(
                   earlierEnd: last.upperBound,
                   laterStart: range.lowerBound) {
                merged[merged.count - 1] =
                    last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The complete microphone volume timeline: quiet by default, ramped up
    /// just before each local turn and back down just after it. `audibleRanges`
    /// leaves two ranges separate only when `canDuckBetween` holds for them, so
    /// consecutive ramps here can never overlap.
    public static func volumeSchedule(
        audibleRanges ranges: [ClosedRange<TimeInterval>],
        duration: TimeInterval
    ) -> [CleanPlaybackVolumeEvent] {
        let audible = audibleRanges(ranges, duration: duration)
        guard !audible.isEmpty else { return [] }

        var events: [CleanPlaybackVolumeEvent] = [
            .level(volume: backgroundMicrophoneGain, at: 0)
        ]
        for range in audible {
            let attackStart = max(0, range.lowerBound - attack)
            if attackStart < range.lowerBound {
                events.append(.ramp(
                    from: backgroundMicrophoneGain,
                    to: 1,
                    start: attackStart,
                    end: range.lowerBound))
            } else {
                events.append(.level(volume: 1, at: range.lowerBound))
            }
            events.append(.level(volume: 1, at: range.upperBound))
            let releaseEnd = min(duration, range.upperBound + release)
            if releaseEnd > range.upperBound {
                events.append(.ramp(
                    from: 1,
                    to: backgroundMicrophoneGain,
                    start: range.upperBound,
                    end: releaseEnd))
            }
        }
        return events
    }

    /// Every event must start no earlier than the previous one ended, and no
    /// ramp may be empty or inverted. AVFoundation aborts the process instead
    /// of returning an error when this is violated, so the boundary checks it.
    public static func isStrictlyOrdered(
        _ schedule: [CleanPlaybackVolumeEvent]
    ) -> Bool {
        var cursor = -TimeInterval.infinity
        for event in schedule {
            guard event.start.isFinite,
                  event.end.isFinite,
                  event.start >= cursor
            else { return false }
            if case .ramp = event, event.end <= event.start { return false }
            cursor = event.end
        }
        return true
    }
}
