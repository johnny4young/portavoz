import Foundation

/// Pure interval math for playback filters. Turns the user's speaking
/// intervals into the gaps to SKIP when "solo mi voz" is on — the
/// complement of the merged voice ranges within [0, duration].
public enum PlaybackRanges {
    /// Merges overlapping/adjacent intervals (sorted by start), padding each
    /// by `margin` so a jump never clips the first or last word.
    public static func merge(
        _ intervals: [ClosedRange<TimeInterval>], margin: TimeInterval = 0.25
    ) -> [ClosedRange<TimeInterval>] {
        let padded = intervals
            .map { max(0, $0.lowerBound - margin)...($0.upperBound + margin) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in padded {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The gaps between (and around) the voice ranges within [0, duration] —
    /// what playback should skip over when only the user's turns should play.
    public static func complement(
        of voiceRanges: [ClosedRange<TimeInterval>], within duration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0 else { return [] }
        let merged = merge(voiceRanges).map {
            max(0, $0.lowerBound)...min(duration, $0.upperBound)
        }.filter { $0.lowerBound < $0.upperBound }
        guard !merged.isEmpty else { return [0...duration] }

        var gaps: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0
        for range in merged {
            if range.lowerBound > cursor {
                gaps.append(cursor...range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < duration {
            gaps.append(cursor...duration)
        }
        return gaps
    }
}
