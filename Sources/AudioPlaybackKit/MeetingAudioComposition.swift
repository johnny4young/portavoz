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
    private static func cleanMix(
        for microphoneTrack: AVCompositionTrack,
        duration: TimeInterval,
        audibleRanges: [ClosedRange<TimeInterval>]
    ) -> AVAudioMix? {
        let ranges = CleanPlaybackPolicy.audibleRanges(
            audibleRanges,
            duration: duration)
        guard !ranges.isEmpty else { return nil }

        let parameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
        let background = CleanPlaybackPolicy.backgroundMicrophoneGain
        parameters.setVolume(background, at: .zero)

        for range in ranges {
            let attackStart = max(0, range.lowerBound - CleanPlaybackPolicy.attack)
            if attackStart < range.lowerBound {
                parameters.setVolumeRamp(
                    fromStartVolume: background,
                    toEndVolume: 1,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: attackStart, preferredTimescale: 600),
                        end: CMTime(seconds: range.lowerBound, preferredTimescale: 600)))
            } else {
                parameters.setVolume(1, at: CMTime(
                    seconds: range.lowerBound,
                    preferredTimescale: 600))
            }
            parameters.setVolume(
                1,
                at: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            let releaseEnd = min(
                duration,
                range.upperBound + CleanPlaybackPolicy.release)
            if releaseEnd > range.upperBound {
                parameters.setVolumeRamp(
                    fromStartVolume: 1,
                    toEndVolume: background,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: range.upperBound, preferredTimescale: 600),
                        end: CMTime(seconds: releaseEnd, preferredTimescale: 600)))
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

/// Pure policy behind clear playback, separated from AVFoundation so boundary
/// and failure behavior stay deterministic in unit tests.
public enum CleanPlaybackPolicy {
    public static let backgroundMicrophoneGain: Float = 0
    public static let attack: TimeInterval = 0.06
    public static let release: TimeInterval = 0.12

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
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] =
                    last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
