import Foundation
import PortavozCore

/// Turns the live diarizer's output into on-screen speaker hints while the
/// meeting is still recording (field ask, jul 2026: two back-to-back remote
/// voices coalesced into one "Them" row — you couldn't tell two people were
/// talking).
///
/// Pure and idempotent: closed system rows are split at turn boundaries via
/// `SpeakerAttributor` (words dealt proportionally to time) and labeled by
/// voice ("S1", "S2", or "Me" when the voiceprint matches through the
/// system channel). The LAST row is never touched — the coalescer may still
/// be growing it; it earns its label once the next row opens and the next
/// diarization window covers it. Labels are ephemeral display hints: the
/// batch pass at stop re-attributes the whole meeting from the file.
public enum LiveSpeakerLabeler {
    public struct Result: Sendable {
        /// Captions with closed multi-voice system rows split per voice.
        /// Rows the turns don't cover (or single-voice rows) keep their id.
        public let captions: [TranscriptSegment]
        /// Row id → live voice label ("S1", "S2", "Me").
        public let labels: [UUID: String]
    }

    public static func relabel(
        captions: [TranscriptSegment],
        turns: [SpeakerTurn],
        meetingID: MeetingID
    ) -> Result {
        guard !turns.isEmpty, captions.count > 1 else {
            return Result(captions: captions, labels: [:])
        }

        let closed = Array(captions.dropLast())
        let attribution = SpeakerAttributor.attribute(
            segments: closed, turns: turns, meetingID: meetingID)
        let labelsByID = Dictionary(
            uniqueKeysWithValues: attribution.speakers.map { ($0.id, $0.label) })

        var labels: [UUID: String] = [:]
        for row in attribution.segments where row.channel != .microphone {
            if let speakerID = row.speakerID, let label = labelsByID[speakerID] {
                labels[row.id] = label
            }
        }
        // The still-growing row rides along untouched at the end.
        return Result(
            captions: attribution.segments + [captions[captions.count - 1]],
            labels: labels)
    }
}
