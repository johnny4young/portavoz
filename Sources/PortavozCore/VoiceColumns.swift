import Foundation

/// Who spoke when, folded into equal time columns: each column holds the voice
/// with the most speech inside it, or silence when nobody covers 30% of it.
public enum VoiceColumns {
    /// The column value for nobody speaking.
    public static let silence: UInt8 = 255
    /// The most columns one strip draws, the waveform's bucket limit.
    public static let maximumCount = 2_000
    /// Columns kept per meeting so library rows and Today draw without a transcript.
    public static let storedCount = 200
    /// Voice indexes stop below `silence`.
    public static let maximumVoices = Int(silence)
    static let coverage = 0.3

    public struct Turn: Sendable, Equatable {
        public let voice: Int
        public let start: TimeInterval
        public let end: TimeInterval

        public init(voice: Int, start: TimeInterval, end: TimeInterval) {
            self.voice = voice
            self.start = start
            self.end = end
        }
    }

    public struct Voice<Key: Hashable & Sendable>: Sendable, Equatable {
        public let key: Key
        public var talkSeconds: TimeInterval
        public let firstHeard: TimeInterval
    }

    public struct Strip<Key: Hashable & Sendable>: Sendable, Equatable {
        public let duration: TimeInterval
        /// Index into `voices` per column, or `silence`.
        public let columns: [UInt8]
        /// Every voice heard, first heard first.
        public let voices: [Voice<Key>]
    }

    /// Indexes voices in first-heard order and bins their turns. The duration
    /// stretches to the last turn when the audio is shorter.
    public static func strip<Key>(
        _ turns: [(key: Key, start: TimeInterval, end: TimeInterval)],
        duration: TimeInterval, count: Int
    ) -> Strip<Key> {
        var indexes: [Key: Int] = [:]
        var voices: [Voice<Key>] = []
        var binned: [Turn] = []
        // NaN breaks the sort's ordering, so invalid turns go before sorting.
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        for turn in valid.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            let index: Int
            if let known = indexes[turn.key] {
                index = known
            } else {
                guard voices.count < maximumVoices else { continue }
                index = voices.count
                indexes[turn.key] = index
                voices.append(Voice(key: turn.key, talkSeconds: 0, firstHeard: max(0, turn.start)))
            }
            voices[index].talkSeconds += turn.end - turn.start
            binned.append(Turn(voice: index, start: turn.start, end: turn.end))
        }
        let length = max(duration.isFinite ? duration : 0, binned.map(\.end).max() ?? 0)
        return Strip(
            duration: length,
            columns: voices.isEmpty ? [] : bin(binned, duration: length, count: count),
            voices: voices)
    }

    /// Voice index per column. Ties go to the lower voice index; turns outside
    /// `0..<duration` are clipped and invalid voices are ignored.
    public static func bin(_ turns: [Turn], duration: TimeInterval, count: Int) -> [UInt8] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        let count = min(count, maximumCount)
        let stride = min(maximumVoices, (turns.map(\.voice).max() ?? -1) + 1)
        guard stride > 0 else { return Array(repeating: silence, count: count) }
        let slice = duration / Double(count)
        var seconds = [Double](repeating: 0, count: count * stride)
        for turn in turns where (0..<stride).contains(turn.voice) {
            let start = max(0, turn.start)
            let end = min(duration, turn.end)
            guard start.isFinite, end.isFinite, end > start else { continue }
            let first = min(count - 1, Int(start / slice))
            let last = min(count - 1, Int(end / slice))
            for column in first...last {
                let lower = Double(column) * slice
                let overlap = min(end, lower + slice) - max(start, lower)
                if overlap > 0 { seconds[column * stride + turn.voice] += overlap }
            }
        }
        let threshold = slice * coverage - slice * 1e-9
        return (0..<count).map { column -> UInt8 in
            var best = -1
            var bestSeconds = 0.0
            for voice in 0..<stride where seconds[column * stride + voice] > bestSeconds {
                best = voice
                bestSeconds = seconds[column * stride + voice]
            }
            return best >= 0 && bestSeconds >= threshold ? UInt8(best) : silence
        }
    }

    /// One accepted transcript line before corrections.
    public struct Line: Sendable, Equatable {
        public let id: UUID
        public let speaker: SpeakerID?
        public let start: TimeInterval
        public let end: TimeInterval

        public init(id: UUID, speaker: SpeakerID?, start: TimeInterval, end: TimeInterval) {
            self.id = id
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    /// One readable line after effective corrections. A split part keeps the
    /// accepted segment it came from and carries its own text.
    public struct AttributedLine: Sendable, Equatable {
        public let id: UUID
        public let segmentID: UUID?
        public let speaker: SpeakerID
        public let start: TimeInterval
        public let end: TimeInterval
        public let partText: String?
    }

    /// Who spoke after effective corrections: speaker changes reassign lines,
    /// suppressions drop them and splits replace them with their parts. Text
    /// edits and same-speaker merges leave attribution as it is.
    public static func attributedTurns(
        lines: [Line],
        corrections: [TranscriptCorrectionEvent]
    ) -> [(key: SpeakerID, start: TimeInterval, end: TimeInterval)] {
        attributedLines(lines: lines, corrections: corrections)
            .map { (key: $0.speaker, start: $0.start, end: $0.end) }
    }

    /// The same attribution as `attributedTurns`, keeping each line's identity.
    public static func attributedLines(
        lines: [Line],
        corrections: [TranscriptCorrectionEvent]
    ) -> [AttributedLine] {
        var speakers = Dictionary(
            lines.map { ($0.id, $0.speaker) }, uniquingKeysWith: { first, _ in first })
        let accepted = Set(lines.map(\.id))
        var removed = Set<UUID>()
        var turns: [AttributedLine] = []
        for correction in corrections {
            switch correction.kind {
            case .changeSpeaker(let speaker):
                for target in correction.targetSegmentIDs { speakers.updateValue(speaker, forKey: target) }
            case .suppress:
                removed.formUnion(correction.targetSegmentIDs)
            case .split(let parts):
                removed.formUnion(correction.targetSegmentIDs)
                // A split of a tombstoned line must not bring its speech back.
                guard correction.targetSegmentIDs.allSatisfy(accepted.contains) else { break }
                turns += parts.compactMap { part in
                    part.speakerID.map {
                        AttributedLine(
                            id: part.id, segmentID: correction.targetSegmentIDs.first, speaker: $0,
                            start: part.startTime, end: part.endTime, partText: part.text)
                    }
                }
            case .replaceText, .merge, .restore:
                break
            }
        }
        for line in lines where !removed.contains(line.id) {
            if case let speaker?? = speakers[line.id] {
                turns.append(AttributedLine(
                    id: line.id, segmentID: line.id, speaker: speaker,
                    start: line.start, end: line.end, partText: nil))
            }
        }
        return turns
    }
}
