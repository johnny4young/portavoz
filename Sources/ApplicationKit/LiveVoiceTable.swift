import Foundation

/// The recording's live Voices table: whoever speaks now on top, then the
/// most recent voices, and everyone past the cast folded into "Others · n".
public struct LiveVoiceTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let voice: VoiceCast.Voice
        /// Seconds into the recording this voice was last heard.
        public let lastHeard: TimeInterval
        public let isSpeaking: Bool
        /// This voice's latest turn while it is the current speaker.
        public let currentTurn: ClosedRange<TimeInterval>?
        public var id: String { voice.key }

        /// How long the turn in progress has lasted at `now`; nil once the
        /// turn is older than the current-speaker window, as when your
        /// microphone opens before a new row is transcribed.
        public func speakingFor(at now: TimeInterval) -> TimeInterval? {
            guard let turn = currentTurn,
                  now - turn.upperBound <= LiveVoiceStage.currentWindow + 1
            else { return nil }
            return max(0, now - turn.lowerBound)
        }
    }

    /// You and the promoted voices, current speaker first, then by recency.
    public let rows: [Row]
    /// Voices past the cast, by talk share.
    public let others: [Row]

    public var isEmpty: Bool { rows.isEmpty && others.isEmpty }
    public let othersShare: Double
    /// The largest share on screen, so the longest bar fills its track.
    public let widestShare: Double

    public init(stage: LiveVoiceStage, cast: VoiceCast) {
        func row(_ voice: VoiceCast.Voice) -> Row? {
            guard let live = stage.voice(voice.key) else { return nil }
            let speaking = stage.current == voice.key
            return Row(
                voice: voice, lastHeard: live.lastHeard, isSpeaking: speaking,
                currentTurn: speaking ? live.turns.last : nil)
        }
        rows = cast.voices.compactMap(row)
        others = cast.others.compactMap(row)
        othersShare = others.reduce(0) { $0 + $1.voice.share }
        widestShare = max(rows.map(\.voice.share).max() ?? 0, othersShare)
    }

    /// The bar's share of its track; the bar clamps it to 0…1.
    public func barFraction(_ share: Double) -> Double {
        widestShare > 0 ? share / widestShare : 0
    }
}
