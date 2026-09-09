import Foundation
import PortavozCore

/// Merges transcript segments with diarization turns into a speaker-
/// attributed transcript. Pure functions — the core of "who said what":
///
/// - `.microphone` segments are the user by hardware truth (D5): they get
///   the "Me" speaker with zero ML involved.
/// - System-channel turns the diarizer matched against the enrolled
///   voiceprint arrive labeled "Me" too (M6): same speaker record, so the
///   user's voice through a room mic still counts as theirs.
/// - `.system`/`.room` segments take the diarization turn with the largest
///   temporal overlap. A segment spanning *several* turns (long batch
///   segments) is split at the turn boundaries, distributing its words
///   proportionally to time — coarse, but far better for who-said-what
///   than handing six turns of text to one speaker.
/// - Segments no turn covers keep `speakerID == nil` (better unattributed
///   than misattributed).
public enum SpeakerAttributor {
    public struct Attribution: Sendable {
        /// Segments with `speakerID` filled in where attribution held;
        /// multi-turn segments arrive split into per-speaker pieces.
        public let segments: [TranscriptSegment]
        /// One record per distinct voice, "Me" first when present.
        public let speakers: [Speaker]
    }

    public static func attribute(
        segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        meetingID: MeetingID
    ) -> Attribution {
        var speakersByLabel: [String: Speaker] = [:]

        func speaker(labeled label: String, isMe: Bool) -> Speaker {
            if let existing = speakersByLabel[label] { return existing }
            let created = Speaker(meetingID: meetingID, label: label, isMe: isMe)
            speakersByLabel[label] = created
            return created
        }

        let index = TurnIndex(turns)
        var attributed: [TranscriptSegment] = []
        for segment in segments {
            if segment.channel == .microphone {
                var mine = segment
                mine.speakerID = speaker(labeled: "Me", isMe: true).id
                attributed.append(mine)
                continue
            }

            let pieces = slice(segment, across: index.window(for: segment))
            if pieces.count <= 1 {
                var copy = segment
                copy.speakerID = pieces.first?.voiceLabel.map {
                    speaker(labeled: $0, isMe: $0 == "Me").id
                }
                attributed.append(copy)
                continue
            }
            var preservesSourceIdentity = true
            for piece in pieces where !piece.text.isEmpty {
                attributed.append(
                    TranscriptSegment(
                        id: preservesSourceIdentity ? segment.id : UUID(),
                        meetingID: segment.meetingID,
                        speakerID: piece.voiceLabel.map {
                            speaker(labeled: $0, isMe: $0 == "Me").id
                        },
                        channel: segment.channel,
                        text: piece.text,
                        language: segment.language,
                        startTime: piece.startTime,
                        endTime: piece.endTime,
                        confidence: segment.confidence,
                        isFinal: segment.isFinal
                    ))
                preservesSourceIdentity = false
            }
        }

        let speakers = speakersByLabel.values.sorted { first, second in
            if first.isMe != second.isMe { return first.isMe }
            return first.label < second.label
        }
        return Attribution(segments: attributed, speakers: speakers)
    }

    // MARK: - Multi-turn slicing

    struct Piece: Equatable {
        /// nil = no turn covered this stretch.
        let voiceLabel: String?
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    /// Cuts a segment at the boundaries of the turns it spans and deals its
    /// words out proportionally to each piece's duration. One or zero
    /// overlapping turns → a single piece (whole segment, that label/nil).
    static func slice(_ segment: TranscriptSegment, across turns: [SpeakerTurn]) -> [Piece] {
        let overlapping = turns
            .filter { overlap($0, segment) > 0 }
            .sorted { $0.startTime < $1.startTime }

        // Merge back-to-back turns of the same voice so we never split
        // between them.
        var merged: [(label: String, start: TimeInterval, end: TimeInterval)] = []
        for turn in overlapping {
            let start = max(turn.startTime, segment.startTime)
            let end = min(turn.endTime, segment.endTime)
            if var last = merged.last, last.label == turn.voiceLabel {
                last.end = max(last.end, end)
                merged[merged.count - 1] = last
            } else {
                merged.append((turn.voiceLabel, start, end))
            }
        }

        guard merged.count > 1, segment.endTime > segment.startTime else {
            return [
                Piece(
                    voiceLabel: merged.first?.label,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.text)
            ]
        }

        // Cut midway through the space between consecutive turns (also the
        // right answer when turns overlap: the midpoint of the overlap).
        var cuts: [TimeInterval] = [segment.startTime]
        for index in 0..<(merged.count - 1) {
            cuts.append((merged[index].end + merged[index + 1].start) / 2)
        }
        cuts.append(segment.endTime)

        let words = segment.text.split(separator: " ").map(String.init)
        let totalDuration = segment.endTime - segment.startTime
        var pieces: [Piece] = []
        var dealt = 0
        for index in 0..<merged.count {
            let start = cuts[index]
            let end = max(start, cuts[index + 1])
            let isLast = index == merged.count - 1
            let share = Int((Double(words.count) * ((end - start) / totalDuration)).rounded())
            let count = isLast ? words.count - dealt : min(max(share, 0), words.count - dealt)
            let text = words[dealt..<(dealt + count)].joined(separator: " ")
            dealt += count
            pieces.append(
                Piece(voiceLabel: merged[index].label, startTime: start, endTime: end, text: text))
        }
        return pieces
    }

    static func overlap(_ turn: SpeakerTurn, _ segment: TranscriptSegment) -> TimeInterval {
        max(0, min(turn.endTime, segment.endTime) - max(turn.startTime, segment.startTime))
    }
}

/// Turn lookup for attribution.
///
/// `slice` filters every turn for every segment, which made live relabeling
/// O(segments x turns) per new turn and O(turns^2 x segments) over a meeting.
/// Turns sorted by start, plus their running maximum end, give each segment a
/// window that provably contains every overlapping turn, so `slice` sees the
/// same set it always did.
private struct TurnIndex {
    private let ordered: [SpeakerTurn]
    private let maximumEnd: [TimeInterval]

    init(_ turns: [SpeakerTurn]) {
        let ordered = turns.sorted { $0.startTime < $1.startTime }
        var maximumEnd: [TimeInterval] = []
        maximumEnd.reserveCapacity(ordered.count)
        var running = -Double.infinity
        for turn in ordered {
            running = max(running, turn.endTime)
            maximumEnd.append(running)
        }
        self.ordered = ordered
        self.maximumEnd = maximumEnd
    }

    /// A turn before the first index whose running maximum end passes the
    /// segment's start ends at or before it, and a turn whose start reaches the
    /// segment's end begins after it; neither can overlap.
    func window(for segment: TranscriptSegment) -> [SpeakerTurn] {
        guard !ordered.isEmpty else { return [] }
        let lower = Self.lowerBound(in: maximumEnd.indices) {
            maximumEnd[$0] > segment.startTime
        }
        let upper = Self.lowerBound(in: ordered.indices) {
            ordered[$0].startTime >= segment.endTime
        }
        guard lower < upper else { return [] }
        return Array(ordered[lower..<upper])
    }

    /// First index in `range` satisfying a predicate that is false then true.
    private static func lowerBound(
        in range: Range<Int>,
        where predicate: (Int) -> Bool
    ) -> Int {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(middle) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
