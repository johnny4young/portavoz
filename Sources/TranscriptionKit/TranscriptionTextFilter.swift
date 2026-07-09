import Foundation
import PortavozCore

/// Small, deterministic transcript hygiene rules shared by live captions and
/// the quality pass. These are intentionally conservative: ASR should keep
/// real words, but punctuation-only deltas and repeated silence boilerplate
/// should not become meeting facts.
enum TranscriptionTextFilter {
    private static let lexicalCharacters = CharacterSet.letters.union(.decimalDigits)
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let separators = whitespace.union(.punctuationCharacters)
    private static let space = Unicode.Scalar(" ")
    private static let silenceHallucinations: Set<String> = [
        "thank you",
        "thanks",
        "thank you for watching",
        "thanks for watching"
    ]

    static func hasLexicalContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { lexicalCharacters.contains($0) }
    }

    static func normalizedPhrase(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = true
        for scalar in folded.unicodeScalars {
            if lexicalCharacters.contains(scalar) {
                scalars.append(scalar)
                previousWasSpace = false
            } else if separators.contains(scalar) {
                guard !previousWasSpace else { continue }
                scalars.append(space)
                previousWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func isKnownSilenceHallucination(_ text: String) -> Bool {
        silenceHallucinations.contains(normalizedPhrase(text))
    }

    /// Whisper silence hallucinations often arrive as the same short phrase
    /// every VAD window (≈30 s). Drop only the repeated/regular pattern so a
    /// single genuine "Thank you" still survives.
    static func repeatedSilenceHallucinationPhrases(
        in segments: [TranscriptSegment],
        minimumCount: Int = 3
    ) -> Set<String> {
        var startsByPhrase: [String: [TimeInterval]] = [:]
        for segment in segments
            where segment.channel == .microphone && isKnownSilenceHallucination(segment.text) {
            startsByPhrase[normalizedPhrase(segment.text), default: []].append(segment.startTime)
        }

        return Set(startsByPhrase.compactMap { phrase, starts in
            guard starts.count >= minimumCount, looksLikeVADCadence(starts) else { return nil }
            return phrase
        })
    }

    private static func looksLikeVADCadence(_ starts: [TimeInterval]) -> Bool {
        let sorted = starts.sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.0 - $0.1 }
        guard gaps.count >= 2 else { return false }
        guard gaps.allSatisfy({ $0 >= 5 }) else { return false }

        let orderedGaps = gaps.sorted()
        let median = orderedGaps[orderedGaps.count / 2]
        guard median >= 8 else { return false }
        let tolerance = max(3, median * 0.25)
        let regularCount = gaps.filter { abs($0 - median) <= tolerance }.count
        return regularCount >= max(2, gaps.count - 1)
    }
}
