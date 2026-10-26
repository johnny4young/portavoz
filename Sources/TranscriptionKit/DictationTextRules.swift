import Foundation

/// One user-defined deterministic correction: whenever the ASR hears the
/// trigger as a standalone word, type the replacement instead. The
/// replacement is the user's spelling authority — applied verbatim,
/// including its casing.
public struct DictationReplacement: Codable, Equatable, Sendable {
    public let trigger: String
    public let replacement: String

    public init(trigger: String, replacement: String) {
        self.trigger = trigger
        self.replacement = replacement
    }
}

/// The deterministic tier of the two-tier dictation dictionary. The other
/// tier is the vocabulary prompt, which biases WhisperEngine (prompt tokens)
/// and SpeechAnalyzerEngine (contextual strings) during transcription but is
/// not consumed by the live Parakeet path that dictation runs, so for
/// dictation these rules are the only dictionary that changes the text.
/// They run AFTER transcription, on the final text only — never on meeting
/// transcripts, which must stay verbatim records.
public enum DictationTextRules {
    /// Non-lexical hesitation fillers in the two supported dictation
    /// languages. Deliberately conservative: every entry is meaningless in
    /// BOTH languages as a standalone token, so real words ("este", "pues",
    /// "well") are never touched.
    static let fillers: Set<String> = [
        "um", "uh", "uhm", "uhh", "er", "erm", "hmm", "mhm", "mmm",
        "eh", "ehm"
    ]

    // Spoken layout commands; a phrase holding a user's trigger stays literal.
    // Escaped so the English-source guard does not read them as Spanish prose.
    static let lineBreakCommands = ["new line", "nueva l\u{ED}nea", "nueva linea"]
    static let paragraphCommands = ["new paragraph", "nuevo p\u{E1}rrafo", "nuevo parrafo", "punto y aparte"]

    public static func apply(
        _ text: String,
        replacements: [DictationReplacement],
        removeFillers: Bool,
        spokenCommands: Bool = false
    ) -> String {
        var result = text
        if removeFillers {
            result = strippingFillers(result)
        }
        var keepsBreaks = false
        if spokenCommands {
            let commanded = applyingSpokenCommands(to: result, except: replacements.map(\.trigger))
            keepsBreaks = commanded != result
            result = commanded
        }
        result = applying(replacements, to: result)
        // A break the user asked for at either end is part of the text.
        return result.trimmingCharacters(in: keepsBreaks ? .whitespaces : .whitespacesAndNewlines)
    }

    /// The phrase becomes a line or paragraph break. The commas and closing
    /// punctuation the recognizer adds around a command are dropped; sentence
    /// punctuation before it stays ("Hi. New line. World" → "Hi.\nWorld").
    static func applyingSpokenCommands(to text: String, except triggers: [String]) -> String {
        // Any user trigger inside a phrase, as whole words, keeps that phrase literal.
        let claimed = { (phrase: String) in
            triggers.contains { trigger in
                let pattern = "(?<![\\p{L}\\p{N}])"
                    + NSRegularExpression.escapedPattern(for: trigger.trimmingCharacters(in: .whitespaces))
                    + "(?![\\p{L}\\p{N}])"
                return phrase.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        // Decomposed accents (i + U+0301) must match the precomposed phrases.
        var result = text.precomposedStringWithCanonicalMapping
        for (phrases, replacement) in [(paragraphCommands, "\n\n"), (lineBreakCommands, "\n")] {
            let active = phrases.filter { !claimed($0) }.sorted { $0.count > $1.count }
            guard !active.isEmpty else { continue }
            let alternatives = active.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let pattern = "[ \\t]*[,;]?[ \\t]*(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])[.,;:!?]*[ \\t]*"
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
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

    /// One regex pass prevents replacements from cascading into later rules:
    /// when "alpha" → "beta" and "beta" → "gamma", dictated "alpha" remains
    /// "beta" — the first matching rule is the user's spelling authority.
    /// Longest trigger first makes "pull request" win over "pull"; matches
    /// remain case-insensitive whole words with punctuation-aware boundaries.
    static func applying(
        _ replacements: [DictationReplacement], to text: String
    ) -> String {
        let ordered = canonical(replacements)
            .sorted { $0.trigger.count > $1.trigger.count }
        guard !ordered.isEmpty else { return text }

        let alternatives = ordered
            .map { NSRegularExpression.escapedPattern(for: $0.trigger) }
            .joined(separator: "|")
        let pattern =
            "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive])
        else { return text }

        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = expression.matches(
            in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let heard = source.substring(with: match.range)
            guard let rule = ordered.first(where: {
                $0.trigger.compare(
                    heard, options: [.caseInsensitive]) == .orderedSame
            }) else { continue }
            // Replace exact ranges rather than regex templates: "$1" and "\"
            // in a user's preferred spelling must remain literal.
            result.replaceCharacters(in: match.range, with: rule.replacement)
        }
        return result as String
    }

    // MARK: - Storage codec (UserDefaults carries the rules as one JSON string)

    public static func decode(replacements json: String) -> [DictationReplacement] {
        guard let data = json.data(using: .utf8),
            let rules = try? JSONDecoder().decode(
                [DictationReplacement].self, from: data)
        else { return [] }
        return canonical(rules)
    }

    public static func encode(_ replacements: [DictationReplacement]) -> String {
        guard let data = try? JSONEncoder().encode(canonical(replacements)),
            let json = String(bytes: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Settings normally writes clean rules, but defaults can be edited or
    /// inherited from older builds. Keep the newest case-insensitive trigger,
    /// trim trigger edges, and reject deletion-shaped empty values so the UI
    /// never receives duplicate ForEach identities or dead matchers.
    /// The ordered semantic value shared by matching, storage and import review.
    public static func canonical(
        _ replacements: [DictationReplacement]
    ) -> [DictationReplacement] {
        var newestFirst: [DictationReplacement] = []
        for rule in replacements.reversed() {
            let trigger = rule.trigger.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trigger.isEmpty,
                !rule.replacement.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                !newestFirst.contains(where: {
                    $0.trigger.compare(
                        trigger, options: [.caseInsensitive]) == .orderedSame
                })
            else { continue }
            newestFirst.append(DictationReplacement(
                trigger: trigger, replacement: rule.replacement))
        }
        return newestFirst.reversed()
    }
}
