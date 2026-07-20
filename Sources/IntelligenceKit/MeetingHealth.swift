import Foundation
import PortavozCore

/// Per-meeting conversation analytics (M13b), computed 100% locally from the
/// attributed transcript — no model involved. Everything is a heuristic over
/// segment times and text, so the numbers are honest approximations:
/// interruptions come from temporal overlap between different speakers, and
/// questions from question marks (covers Spanish and English punctuation,
/// since inverted marks always pair with a closing one).
public struct MeetingHealth: Sendable, Equatable {
    public struct SpeakerStat: Sendable, Equatable, Identifiable {
        public var id: SpeakerID { speakerID }
        public let speakerID: SpeakerID
        /// Attributed speech, in seconds.
        public let speechSeconds: TimeInterval
        /// Fraction (0…1) of the meeting's attributed speech.
        public let share: Double
        /// Segments by this speaker containing a question.
        public let questions: Int
        /// Times this speaker started talking while someone else still was.
        public let interruptionsMade: Int
        /// Longest run of uninterrupted speech (chained segments, gaps ≤ 2 s).
        public let longestMonologue: TimeInterval
    }

    /// One entry per attributed speaker, longest talk time first.
    public let stats: [SpeakerStat]
    public let totalSpeechSeconds: TimeInterval
    public let questionsTotal: Int
    public let interruptionsTotal: Int

    /// Two speakers genuinely overlapping for at least this long counts as
    /// an interruption; anything shorter is backchannel ("mm-hm") or timing
    /// noise between the two capture channels.
    static let interruptionOverlap: TimeInterval = 0.5
    /// Same-speaker segments closer than this chain into one monologue.
    static let monologueGap: TimeInterval = 2.0

    public static func compute(segments: [TranscriptSegment]) -> MeetingHealth {
        let attributed = segments
            .filter { $0.speakerID != nil && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard !attributed.isEmpty else {
            return MeetingHealth(
                stats: [], totalSpeechSeconds: 0, questionsTotal: 0, interruptionsTotal: 0)
        }

        var seconds: [SpeakerID: TimeInterval] = [:]
        var questions: [SpeakerID: Int] = [:]
        var interruptions: [SpeakerID: Int] = [:]
        var monologue: [SpeakerID: TimeInterval] = [:]

        for segment in attributed {
            guard let speaker = segment.speakerID else { continue }
            seconds[speaker, default: 0] += segment.endTime - segment.startTime
            if segment.text.contains("?") {
                questions[speaker, default: 0] += 1
            }
        }

        countInterruptions(in: attributed, into: &interruptions)
        measureMonologues(in: attributed, into: &monologue)

        let total = seconds.values.reduce(0, +)
        let stats = seconds
            .map { speaker, speech in
                SpeakerStat(
                    speakerID: speaker,
                    speechSeconds: speech,
                    share: total > 0 ? speech / total : 0,
                    questions: questions[speaker] ?? 0,
                    interruptionsMade: interruptions[speaker] ?? 0,
                    longestMonologue: monologue[speaker] ?? 0)
            }
            .sorted { $0.speechSeconds > $1.speechSeconds }

        return MeetingHealth(
            stats: stats,
            totalSpeechSeconds: total,
            questionsTotal: questions.values.reduce(0, +),
            interruptionsTotal: interruptions.values.reduce(0, +))
    }

    /// B interrupts A when B (another speaker) starts while A is still
    /// talking and the overlap lasts at least `interruptionOverlap`.
    private static func countInterruptions(
        in segments: [TranscriptSegment],
        into counts: inout [SpeakerID: Int]
    ) {
        var prefixMaximumEnd: [TimeInterval] = []
        prefixMaximumEnd.reserveCapacity(segments.count)
        var maximumEnd = -TimeInterval.infinity
        for segment in segments {
            maximumEnd = max(maximumEnd, segment.endTime)
            prefixMaximumEnd.append(maximumEnd)
        }

        for (index, segment) in segments.enumerated() {
            guard let interrupter = segment.speakerID else { continue }
            guard index > 0 else { continue }
            for previousIndex in stride(from: index - 1, through: 0, by: -1) {
                // Once every earlier segment has ended, no older overlap can
                // exist. A plain break on the nearest ended segment would be
                // incorrect because an older, longer segment may still span it.
                guard prefixMaximumEnd[previousIndex] > segment.startTime else { break }
                let previous = segments[previousIndex]
                if previous.endTime <= segment.startTime { continue }
                guard let interrupted = previous.speakerID, interrupted != interrupter else {
                    continue
                }
                let overlap = min(previous.endTime, segment.endTime) - segment.startTime
                if overlap >= interruptionOverlap {
                    counts[interrupter, default: 0] += 1
                    break
                }
            }
        }
    }

    private static func measureMonologues(
        in segments: [TranscriptSegment],
        into longest: inout [SpeakerID: TimeInterval]
    ) {
        var currentSpeaker: SpeakerID?
        var runStart: TimeInterval = 0
        var runEnd: TimeInterval = 0

        func closeRun() {
            guard let speaker = currentSpeaker else { return }
            longest[speaker] = max(longest[speaker] ?? 0, runEnd - runStart)
        }

        for segment in segments {
            guard let speaker = segment.speakerID else { continue }
            if speaker == currentSpeaker, segment.startTime - runEnd <= monologueGap {
                runEnd = max(runEnd, segment.endTime)
            } else {
                closeRun()
                currentSpeaker = speaker
                runStart = segment.startTime
                runEnd = segment.endTime
            }
        }
        closeRun()
    }
}
