import Foundation

/// Mines domain terms from what was actually said in past meetings and
/// suggests them for the custom vocabulary (the ROADMAP's "vocabulary
/// learning"). Conservative on purpose: only tokens that LOOK like domain
/// terms — acronyms (LVGT), letter+digit codes (Cots2M), CamelCase names
/// (WhisperKit) — and that recur across the corpus. Plain capitalized words
/// are ignored (too many false positives: sentence starts, people's names).
public enum VocabularyMiner {
    static let stoplist: Set<String> = ["OK", "AM", "PM", "TV", "ID", "IDs"]

    /// Suggests up to `limit` recurring domain-looking terms not already in
    /// the vocabulary, most frequent first.
    public static func suggest(
        from texts: [String],
        existing: [String],
        minimumOccurrences: Int = 3,
        limit: Int = 8
    ) -> [String] {
        let known = Set(existing.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]

        for text in texts {
            for raw in text.split(whereSeparator: { $0.isWhitespace }) {
                let token = trim(raw)
                guard looksLikeDomainTerm(token) else { continue }
                let key = token.lowercased()
                guard !known.contains(key), !stoplist.contains(token) else { continue }
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = token }
            }
        }

        return counts
            .filter { $0.value >= minimumOccurrences }
            .sorted { first, second in
                first.value != second.value
                    ? first.value > second.value
                    : first.key < second.key
            }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }

    /// Strips punctuation from both edges, keeping interior characters
    /// ("Cots2M," → "Cots2M"; "(WhisperKit)" → "WhisperKit").
    private static func trim(_ raw: Substring) -> String {
        String(raw.drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed()
            .drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed())
    }

    /// Acronym, letter+digit code, or CamelCase — the shapes worth biasing
    /// the transcriber toward. Everything else is normal language.
    static func looksLikeDomainTerm(_ token: String) -> Bool {
        guard token.count >= 2, token.count <= 24 else { return false }
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }

        let hasDigit = token.contains(where: \.isNumber)
        if hasDigit { return true }

        let isAllCaps = letters.allSatisfy(\.isUppercase)
        if isAllCaps { return token.count <= 6 }

        // CamelCase: an uppercase letter AFTER the first character, with
        // lowercase around it (WhisperKit, iPhone) — not ALLCAPS, not "Word".
        let body = token.dropFirst()
        return body.contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }
}
