import Foundation

/// Maps meeting time onto a scrubber where long stretches without speech are
/// drawn short. Speech comes from the transcript, so a quiet room or a hiss
/// still counts as dead time.
public struct PlaybackTimeline: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let range: ClosedRange<TimeInterval>
        public let isGap: Bool
        /// Seconds this part occupies on the scrubber.
        public let displayLength: TimeInterval
    }

    /// Pauses shorter than this are conversation, not dead time.
    static let minimumGap: TimeInterval = 20
    /// Context kept around each transcribed phrase.
    static let speechMargin: TimeInterval = 1

    public let duration: TimeInterval
    public let parts: [Part]
    private let displayDuration: TimeInterval

    public init(duration: TimeInterval, speech: [ClosedRange<TimeInterval>]) {
        self.duration = max(0, duration)
        var gaps: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0
        // Transcript times can run past a shorter audio file; clamp to it.
        for range in PlaybackRanges.merge(speech, margin: Self.speechMargin) {
            let start = min(cursor, self.duration)
            let end = min(range.lowerBound, self.duration)
            if end - start >= Self.minimumGap { gaps.append(start...end) }
            cursor = max(cursor, range.upperBound)
        }
        if self.duration - cursor >= Self.minimumGap { gaps.append(cursor...self.duration) }
        guard !speech.isEmpty, !gaps.isEmpty else {
            parts = self.duration > 0
                ? [Part(range: 0...self.duration, isGap: false, displayLength: self.duration)]
                : []
            displayDuration = self.duration
            return
        }

        let speechTotal = self.duration - gaps.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        // A gap is drawn no longer than a tenth of the conversation (at least
        // ten seconds), so a forgotten Stop cannot swallow the scrubber.
        let gapCap = max(speechTotal * 0.1, 10)
        var built: [Part] = []
        cursor = 0
        for gap in gaps {
            if gap.lowerBound > cursor {
                built.append(Part(
                    range: cursor...gap.lowerBound, isGap: false,
                    displayLength: gap.lowerBound - cursor))
            }
            let length = gap.upperBound - gap.lowerBound
            built.append(Part(range: gap, isGap: true, displayLength: min(length, gapCap)))
            cursor = gap.upperBound
        }
        if cursor < self.duration {
            built.append(Part(
                range: cursor...self.duration, isGap: false, displayLength: self.duration - cursor))
        }
        parts = built
        displayDuration = built.reduce(0) { $0 + $1.displayLength }
    }

    /// Dead time playback skips when Skip silence is on.
    public var gaps: [ClosedRange<TimeInterval>] {
        parts.filter(\.isGap).map(\.range)
    }

    /// Scrubber position (0…1) of a meeting time.
    public func fraction(at time: TimeInterval) -> Double {
        guard displayDuration > 0 else { return 0 }
        var offset: TimeInterval = 0
        for part in parts {
            if time <= part.range.upperBound {
                let length = part.range.upperBound - part.range.lowerBound
                let within = length > 0 ? max(0, time - part.range.lowerBound) / length : 0
                return min(1, (offset + within * part.displayLength) / displayDuration)
            }
            offset += part.displayLength
        }
        return 1
    }

    /// Meeting time under a scrubber position (0…1).
    public func time(at fraction: Double) -> TimeInterval {
        guard displayDuration > 0 else { return 0 }
        var remaining = min(1, max(0, fraction)) * displayDuration
        for part in parts {
            if remaining <= part.displayLength {
                let within = part.displayLength > 0 ? remaining / part.displayLength : 0
                return part.range.lowerBound + within * (part.range.upperBound - part.range.lowerBound)
            }
            remaining -= part.displayLength
        }
        return duration
    }
}
