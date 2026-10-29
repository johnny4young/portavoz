import Foundation

/// Finds where people speak in 16 kHz mono samples.
public protocol SpeechRegionDetecting: Sendable {
    func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>]
}

/// Packs detected speech into the windows Whisper decodes, so silence never
/// reaches the decoder and every window keeps its real timestamps.
public enum SpeechDecodeWindows {
    /// Whisper sees 30 s at a time; packing stops short of that.
    static let maximumWindow: TimeInterval = 28
    /// Pauses up to this long stay inside one window and keep sentence context.
    static let maximumGap: TimeInterval = 2
    static let padding: TimeInterval = 0.2

    public static func plan(
        _ regions: [ClosedRange<TimeInterval>],
        duration: TimeInterval
    ) -> [Range<TimeInterval>] {
        let padded = regions
            .map { max(0, $0.lowerBound - padding)..<min(duration, $0.upperBound + padding) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var windows: [Range<TimeInterval>] = []
        for region in padded {
            guard let last = windows.last else {
                windows.append(region)
                continue
            }
            let joined = last.lowerBound..<max(last.upperBound, region.upperBound)
            if region.lowerBound <= last.upperBound
                || (region.lowerBound - last.upperBound <= maximumGap
                    && joined.upperBound - joined.lowerBound <= maximumWindow) {
                windows[windows.count - 1] = joined
            } else {
                windows.append(region)
            }
        }
        return windows
    }

    /// Each window's decoding language. Automatic detection is limited to the
    /// languages Portavoz supports; a window detected outside them (silence
    /// labelled Japanese, English labelled German) takes the channel majority.
    public static func languages(
        detected: [String?],
        allowed: Set<String>
    ) -> [String?] {
        var counts: [String: Int] = [:]
        for language in detected.compactMap({ $0 }) where allowed.contains(language) {
            counts[language, default: 0] += 1
        }
        let majority = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        return detected.map { language in
            guard let language, allowed.contains(language) else { return majority }
            return language
        }
    }
}
