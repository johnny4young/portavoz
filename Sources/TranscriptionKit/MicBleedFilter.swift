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
        var foundDivergentCrossTalk = false

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

            // A large shared opener or conclusion can still be two people
            // disagreeing at the same instant ("ship Friday" / "ship
            // Monday"). Remember that evidence until every direct row has
            // been checked for an exact or directional echo match; the broad
            // bag-of-words fallback below must never erase the disagreement.
            if actuallyOverlaps,
                hasDivergentSameEdgeOverlap(micWords, remoteWords) {
                foundDivergentCrossTalk = true
            }
        }

        // The broader containment fallback is intentionally reserved for
        // three or more words. Batch ASR timestamps can drift enough that two
        // copies no longer overlap exactly.
        guard micWords.count >= 3 else { return false }
        guard !foundDivergentCrossTalk else { return false }
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

        // Only the two directional continuations are bleed evidence: one
        // row's trailing edge is the other's leading edge (rolling windows
        // truncating the same utterance). They also subsume full containment,
        // because an entire shorter row equals both its own prefix and
        // suffix. Same-edge partial matches must NOT count: cross-talk is
        // exactly when both channels carry distinct speech at once ("so i
        // think we can…" vs "so i think that's premature"), and matching a
        // shared opener would erase the user's real words from the record.
        for length in stride(from: maximum, through: 1, by: -1) {
            if left.suffix(length).elementsEqual(right.prefix(length))
                || right.suffix(length).elementsEqual(left.prefix(length)) {
                return length
            }
        }
        return 0
    }

    private static func hasDivergentSameEdgeOverlap(
        _ left: [String],
        _ right: [String]
    ) -> Bool {
        let maximum = min(left.count, right.count)
        guard maximum > 3 else { return false }

        // Exclude full containment by requiring real content on both sides of
        // the shared edge. Compute each common edge once so this safety check
        // remains linear even for unusually long ASR windows.
        var sharedPrefix = 0
        while sharedPrefix < maximum,
            left[sharedPrefix] == right[sharedPrefix] {
            sharedPrefix += 1
        }
        if sharedPrefix >= 3,
            sharedPrefix < left.count,
            sharedPrefix < right.count {
            return true
        }

        var sharedSuffix = 0
        while sharedSuffix < maximum,
            left[left.count - sharedSuffix - 1]
                == right[right.count - sharedSuffix - 1] {
            sharedSuffix += 1
        }
        return sharedSuffix >= 3
            && sharedSuffix < left.count
            && sharedSuffix < right.count
    }

    private static func words(_ text: String) -> [String] {
        TranscriptionTextFilter.normalizedPhrase(text)
            .split(separator: " ")
            .map(String.init)
    }
}
