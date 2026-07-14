import Foundation

/// Decides whether a transcript segment is likely non-speech noise rather than
/// real words. A far-field or barely-used microphone makes the model emit
/// stray single letters and low-confidence fragments ("R", "SR", "IT'NAKE
/// THINKE") when the user isn't really speaking — garbage that pollutes the
/// transcript, meeting health and chapters. Callers gate the microphone
/// channel on this so silence and room noise don't become text.
///
/// Tuned from field data (jul 2026): real quiet speech scored ≥ 0.6
/// confidence; the noise fragments scored ≤ 0.4.
public enum TranscriptNoiseFilter {
    /// Below this the model was mostly guessing.
    public static let confidenceFloor = 0.42

    private static let vowels = Set("aeiouy")

    public static func isLikelyNoise(text: String, confidence: Double?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let letters = trimmed.filter(\.isLetter)
        // A lone letter (or none) is never a word — "R", "E", "—".
        if letters.count <= 1 { return true }
        let words = trimmed.split(separator: " ")
        // Diacritic-fold so accented Spanish vowels count as vowels.
        let hasVowel = letters.contains { char in
            let base = String(char).folding(options: .diacriticInsensitive, locale: nil)
            return base.contains { vowels.contains($0) }
        }
        // A short single token with no vowel is noise — "SR", "MK".
        if words.count == 1, letters.count <= 3, !hasVowel { return true }
        // Low-confidence fragments the model wasn't sure about.
        if let confidence, confidence < confidenceFloor { return true }
        return false
    }
}
