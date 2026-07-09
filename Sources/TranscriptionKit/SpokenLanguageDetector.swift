import Foundation
import NaturalLanguage
import PortavozCore

/// Infers spoken language from transcript evidence so a quality re-pass
/// preserves what was said instead of drifting toward UI or summary language.
/// Refine only receives a pinned language when the evidence is homogeneous;
/// mixed meetings stay on Whisper auto-detect.
public enum SpokenLanguageDetector {
    private static let minimumLetters = 24
    private static let minimumSegmentLetters = 18
    private static let minimumConfidence = 0.35
    private static let maximumCharacters = 8_000
    private static let letters = CharacterSet.letters

    /// Language to pass into a transcription engine. Returns nil for mixed
    /// or uncertain meetings so multilingual audio remains auto-detected.
    public static func transcriptionLanguageHint(
        for meeting: Meeting,
        segments: [TranscriptSegment]
    ) -> String? {
        homogeneousLanguage(in: segments)
            ?? (segments.isEmpty ? canonicalLanguageCode(meeting.language) : nil)
    }

    /// Meeting-level metadata: only set when all available evidence points
    /// to one language. Mixed or uncertain meetings stay nil.
    public static func homogeneousLanguage(
        in segments: [TranscriptSegment],
        fallback: String? = nil
    ) -> String? {
        let languages = segmentLanguages(in: segments)
        if !languages.isEmpty {
            return singleLanguage(in: languages)
        }

        return inferredLanguage(from: transcriptSample(from: segments))
            ?? canonicalLanguageCode(fallback)
    }

    public static func canonicalLanguageCode(_ raw: String?) -> String? {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty, normalized != "und" else { return nil }
        return normalized.split(separator: "-").first.map(String.init)
    }

    private static func segmentLanguages(in segments: [TranscriptSegment]) -> [String] {
        segments.compactMap { segment in
            canonicalLanguageCode(segment.language)
                ?? inferredLanguage(from: segment.text, minimumLetters: minimumSegmentLetters)
        }
    }

    private static func singleLanguage(in languages: [String]) -> String? {
        guard !languages.isEmpty else { return nil }
        let unique = Set(languages)
        return unique.count == 1 ? languages[0] : nil
    }

    private static func inferredLanguage(
        from sample: String,
        minimumLetters: Int = minimumLetters
    ) -> String? {
        guard sample.unicodeScalars.filter({ letters.contains($0) }).count >= minimumLetters else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard
            let best = hypotheses.max(by: { $0.value < $1.value }),
            best.value >= minimumConfidence
        else {
            return nil
        }
        return canonicalLanguageCode(best.key.rawValue)
    }

    private static func transcriptSample(from segments: [TranscriptSegment]) -> String {
        var sample = ""
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !sample.isEmpty { sample += "\n" }
            sample += text
            if sample.count >= maximumCharacters {
                return String(sample.prefix(maximumCharacters))
            }
        }
        return sample
    }
}
