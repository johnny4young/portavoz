import Foundation
import PortavozCore

/// The Voices table of a finished meeting: each voice of the cast that spoke,
/// with its turns on the meeting's time axis.
public struct MeetingVoiceTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let speakerID: SpeakerID
        public let voice: VoiceCast.Voice
        /// This voice's turns in time order: runs of its segments that nobody
        /// else's segment starts inside.
        public let turns: [ClosedRange<TimeInterval>]
        public var id: String { voice.key }

        /// The first turn starting after `time`, wrapping to the first turn.
        public func nextTurn(after time: TimeInterval) -> TimeInterval? {
            let later = turns.first { $0.lowerBound > time + MeetingVoiceTable.stepTolerance }
            return (later ?? turns.first)?.lowerBound
        }
    }

    /// A seek that lands a frame short of a turn counts as being on it.
    static let stepTolerance: TimeInterval = 0.1

    /// You and the promoted voices, in cast order.
    public let rows: [Row]
    /// Voices folded into "Others · n", by talk share.
    public let others: [Row]
    /// Seconds the rows' time axis spans.
    public let duration: TimeInterval

    public var count: Int { rows.count + others.count }
    public var isEmpty: Bool { rows.isEmpty && others.isEmpty }
    public var othersShare: Double { others.reduce(0) { $0 + $1.voice.share } }
    public var othersTalkSeconds: TimeInterval { others.reduce(0) { $0 + $1.voice.talkSeconds } }

    /// - Parameter meetingLength: wall-clock length; the axis stretches to the
    ///   last turn when the meeting is shorter or still unknown.
    public init(cast: VoiceCast, segments: [TranscriptSegment], meetingLength: TimeInterval = 0) {
        let attributed = segments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .compactMap { segment in
                segment.speakerID.map { (key: $0, start: segment.startTime, end: segment.endTime) }
            }
        let turns = Dictionary(
            VoiceTurnRuns.merge(attributed).turns.map { (VoiceCast.key($0.key), (id: $0.key, turns: $0.value)) },
            uniquingKeysWith: { first, _ in first })
        let lastTurn = turns.values.flatMap(\.turns).map(\.upperBound).max() ?? 0
        duration = max(meetingLength.isFinite ? meetingLength : 0, lastTurn)
        func row(_ voice: VoiceCast.Voice) -> Row? {
            turns[voice.key].map {
                Row(speakerID: $0.id, voice: voice, turns: $0.turns)
            }
        }
        rows = cast.voices.compactMap(row)
        others = cast.others.compactMap(row)
    }
}
