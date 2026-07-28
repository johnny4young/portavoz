import Foundation
import PortavozCore

/// Removes speaker bleed from the refined microphone channel.
///
/// With speakers, the microphone hears the room while the system tap records
/// the same remote speech directly. The microphone copy can be loud enough for
/// Whisper's batch pass to transcribe. Every such segment lands on the "Me"
/// speaker and poisons who-said-what (field evidence, Jul 10: a user who barely
/// spoke showed 52% talk time after refine).
///
/// The tell is textual: a mic segment whose words already appear in the
/// system channel around the same instant is the room, not the user — the
/// system tap records the meeting audio directly, so bleed is always a
/// (noisier) copy of something the system channel has.
public enum MicBleedFilter {
    /// Fraction of a mic segment's words that must appear in the
    /// overlapping system text for the segment to count as bleed.
    static let containmentThreshold = 0.6
    /// Seconds of slack around the mic segment when collecting system text
    /// (transcription timestamps drift a little between engines).
    static let overlapSlackSeconds: TimeInterval = 3

    public static func filter(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !system.isEmpty else { return microphone }
        return microphone.filter { !isBleed($0, system: system) }
    }

    static func isBleed(_ mic: TranscriptSegment, system: [TranscriptSegment]) -> Bool {
        let micWords = words(mic.text)
        // A single word is too little evidence ("yes", "no", a name). Two
        // words are admitted only when both channels cover the same instant
        // and the normalized phrases are exact copies.
        guard micWords.count >= 2 else { return false }

        let nearby = system.filter {
            $0.startTime < mic.endTime + overlapSlackSeconds
                && $0.endTime > mic.startTime - overlapSlackSeconds
        }

        for segment in nearby {
            let remoteWords = words(segment.text)
            guard !remoteWords.isEmpty else { continue }
            let actuallyOverlaps =
                min(mic.endTime, segment.endTime) > max(mic.startTime, segment.startTime)

            if actuallyOverlaps, micWords == remoteWords {
                return true
            }

            // Live engines report overlapping rolling windows. A direct
            // system row may therefore contain only the trailing edge of the
            // noisier microphone copy ("...do it right now" / "it right
            // now"). Three contiguous edge words plus real time overlap are
            // stronger evidence than bag-of-words containment alone.
            if actuallyOverlaps,
                longestContiguousEdgeOverlap(micWords, remoteWords) >= 3 {
                return true
            }
        }

        // The broader containment fallback is intentionally reserved for
        // three or more words. Batch ASR timestamps can drift enough that two
        // copies no longer overlap exactly.
        guard micWords.count >= 3 else { return false }
        var systemWords = Set<String>()
        for segment in nearby {
            systemWords.formUnion(words(segment.text))
        }
        guard !systemWords.isEmpty else { return false }
        let contained = micWords.filter(systemWords.contains).count
        return Double(contained) / Double(micWords.count) >= containmentThreshold
    }

    private static func longestContiguousEdgeOverlap(
        _ left: [String],
        _ right: [String]
    ) -> Int {
        let maximum = min(left.count, right.count)
        guard maximum > 0 else { return 0 }

        for length in stride(from: maximum, through: 1, by: -1) {
            if left.suffix(length).elementsEqual(right.prefix(length))
                || right.suffix(length).elementsEqual(left.prefix(length))
                || left.prefix(length).elementsEqual(right.prefix(length))
                || left.suffix(length).elementsEqual(right.suffix(length)) {
                return length
            }
        }
        return 0
    }

    private static func words(_ text: String) -> [String] {
        TranscriptionTextFilter.normalizedPhrase(text)
            .split(separator: " ")
            .map(String.init)
    }
}
