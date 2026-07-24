import Foundation

/// One user-defined deterministic correction: whenever the ASR hears the
/// trigger as a standalone word, type the replacement instead. The
/// replacement is the user's spelling authority — applied verbatim,
/// including its casing.
public struct DictationReplacement: Codable, Equatable, Sendable {
    public var trigger: String
    public var replacement: String

    public init(trigger: String, replacement: String) {
        self.trigger = trigger
        self.replacement = replacement
    }
}

/// The deterministic tier of the two-tier dictation dictionary (the other
/// tier is the vocabulary prompt, which biases the model DURING
/// transcription). These rules run AFTER transcription, on the final text
/// only — never on meeting transcripts, which must stay verbatim records.
public enum DictationTextRules {
    /// Non-lexical hesitation fillers in the two supported dictation
    /// languages. Deliberately conservative: every entry is meaningless in
    /// BOTH languages as a standalone token, so real words ("este", "pues",
    /// "well") are never touched.
    static let fillers: Set<String> = [
        "um", "uh", "uhm", "uhh", "er", "erm", "hmm", "mhm", "mmm",
        "eh", "ehm"
    ]

    public static func apply(
        _ text: String,
        replacements: [DictationReplacement],
        removeFillers: Bool
    ) -> String {
        var result = text
        if removeFillers {
            result = strippingFillers(result)
        }
        result = applying(replacements, to: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes standalone fillers plus one trailing comma/semicolon each
    /// ("um, hello" → "hello"), then repairs the seams: collapsed spaces
    /// and no space left hanging before closing punctuation ("hello um."
    /// → "hello.").
    static func strippingFillers(_ text: String) -> String {
        let alternation = fillers.sorted { $0.count > $1.count }
            .joined(separator: "|")
        let pattern =
            "(?i)(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}])[,;]?\\s*"
        var result = text.replacingOccurrences(
            of: pattern, with: "", options: [.regularExpression])
        result = result.replacingOccurrences(
            of: "\\s+(?=[.,;:!?…])", with: "", options: [.regularExpression])
        return result.replacingOccurrences(
            of: "\\s{2,}", with: " ", options: [.regularExpression])
    }

    /// Longest trigger first so "pull request" wins over "pull"; matches are
    /// case-insensitive whole words with punctuation-aware boundaries (a
    /// trigger like "k8s" still matches before a comma, and "cat" never
    /// rewrites "concatenate").
    static func applying(
        _ replacements: [DictationReplacement], to text: String
    ) -> String {
        var result = text
        let ordered = replacements
            .filter { !$0.trigger.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        for rule in ordered {
            let escaped = NSRegularExpression.escapedPattern(for: rule.trigger)
            let pattern = "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: rule.replacement),
                options: [.regularExpression])
        }
        return result
    }

    // MARK: - Storage codec (UserDefaults carries the rules as one JSON string)

    public static func decode(replacements json: String) -> [DictationReplacement] {
        guard let data = json.data(using: .utf8),
            let rules = try? JSONDecoder().decode(
                [DictationReplacement].self, from: data)
        else { return [] }
        return rules
    }

    public static func encode(_ replacements: [DictationReplacement]) -> String {
        guard let data = try? JSONEncoder().encode(replacements),
            let json = String(bytes: data, encoding: .utf8)
        else { return "[]" }
        return json
    }
}
