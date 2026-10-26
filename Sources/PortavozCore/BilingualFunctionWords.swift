import Foundation

/// English and Spanish words that carry grammar rather than topic, compared
/// after case and accent folding.
public enum BilingualFunctionWords {
    public static let all: Set<String> = [
        // English
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can",
        "could", "did", "do", "does", "for", "from", "how", "i", "if", "in",
        "is", "it", "of", "on", "or", "that", "the", "they", "this", "to",
        "uh", "um", "we", "what", "when", "where", "which", "who", "with",
        "would", "you",
        // Spanish
        "a", "al", "como", "con", "cual", "cuando", "de", "del", "donde",
        "el", "en", "es", "este", "la", "las", "lo", "los", "o", "para",
        "por", "que", "se", "si", "son", "un", "una", "y", "yo"
    ]

    /// Lowercased, accent-free letter and digit runs.
    public static func foldedTokens(in text: String) -> [String] {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
