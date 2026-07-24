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
        // One- or two-word utterances ("Yeah.", "Thank you") carry too
        // little signal to match reliably — other filters handle those.
        guard micWords.count >= 3 else { return false }
        var systemWords = Set<String>()
        for segment in system
            where segment.startTime < mic.endTime + overlapSlackSeconds
                && segment.endTime > mic.startTime - overlapSlackSeconds {
            systemWords.formUnion(words(segment.text))
        }
        guard !systemWords.isEmpty else { return false }
        let contained = micWords.filter(systemWords.contains).count
        return Double(contained) / Double(micWords.count) >= containmentThreshold
    }

    private static func words(_ text: String) -> [String] {
        TranscriptionTextFilter.normalizedPhrase(text)
            .split(separator: " ")
            .map(String.init)
    }
}
