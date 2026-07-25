import Foundation

/// Word/character error rates for engine comparison (MODEL-001). The bench
/// harness measured only latency until now; swapping the live lane needs an
/// accuracy number measured HERE, on our fixtures, not a citation of
/// third-party tables (the quality spec forbids presenting those as ours).
public enum TranscriptionAccuracy {
    public struct Report: Equatable, Sendable {
        /// Word error rate: substitutions + insertions + deletions over
        /// reference words. Can exceed 1 when the hypothesis rambles.
        public let wordErrorRate: Double
        /// Character error rate over the normalized strings — steadier than
        /// WER on short Spanish clips where one gender suffix flips a word.
        public let characterErrorRate: Double
        public let referenceWords: Int
        public let hypothesisWords: Int
    }

    /// Case-, punctuation-, and whitespace-insensitive; accented letters
    /// SURVIVE normalization because Spanish accents are phonemic — "papa"
    /// versus its accented form is a real transcription difference, not
    /// formatting (the unit tests carry the literal pair as evidence).
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func report(reference: String, hypothesis: String) -> Report {
        let referenceWords = normalize(reference)
            .split(separator: " ").map(String.init)
        let hypothesisWords = normalize(hypothesis)
            .split(separator: " ").map(String.init)
        let wordEdits = editDistance(referenceWords, hypothesisWords)
        let referenceCharacters = Array(normalize(reference))
        let hypothesisCharacters = Array(normalize(hypothesis))
        let characterEdits = editDistance(referenceCharacters, hypothesisCharacters)
        return Report(
            wordErrorRate: referenceWords.isEmpty
                ? (hypothesisWords.isEmpty ? 0 : 1)
                : Double(wordEdits) / Double(referenceWords.count),
            characterErrorRate: referenceCharacters.isEmpty
                ? (hypothesisCharacters.isEmpty ? 0 : 1)
                : Double(characterEdits) / Double(referenceCharacters.count),
            referenceWords: referenceWords.count,
            hypothesisWords: hypothesisWords.count)
    }

    /// Levenshtein with the two-row rolling buffer — reference transcripts
    /// are minutes of speech, so O(n·m) time is fine but O(n·m) memory is
    /// not.
    static func editDistance<Element: Equatable>(
        _ reference: [Element], _ hypothesis: [Element]
    ) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for row in 1...reference.count {
            current[0] = row
            for column in 1...hypothesis.count {
                let substitution = previous[column - 1]
                    + (reference[row - 1] == hypothesis[column - 1] ? 0 : 1)
                current[column] = min(
                    substitution,
                    previous[column] + 1,
                    current[column - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }
}
