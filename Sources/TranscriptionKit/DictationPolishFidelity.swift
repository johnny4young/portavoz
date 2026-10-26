import Foundation
import NaturalLanguage

/// Deterministic guard for a generative dictation rewrite: the polished text may fix
/// form, never facts. Any doubt keeps the clean text, so the checks favor refusal.
public enum DictationPolishFidelity {
    public enum Violation: Equatable, Sendable {
        case numbers
        case identifiers
        case protectedTerm
        case negation
        case length
        case language
        case preamble
        case empty
    }

    static let minimumLengthRatio = 0.6
    static let maximumLengthRatio = 1.4
    private static let languageCheckMinimumLetters = 40
    private static let languageConfidence = 0.8

    private static let negations: Set<String> = [
        "no", "not", "never", "none", "nobody", "nothing", "neither", "nor", "without", "cannot",
        "nunca", "jam\u{E1}s", "nada", "nadie", "ninguno", "ninguna", "ning\u{FA}n", "tampoco", "ni", "sin"
    ]
    private static let preambles = [
        "here is", "here's", "sure", "certainly", "rewritten", "polished", "corrected",
        "aqu\u{ED} est\u{E1}", "aqu\u{ED} tienes", "claro", "por supuesto", "texto corregido", "texto pulido"
    ]

    /// Returns the first rule the candidate breaks, or nil when it is safe to paste.
    /// `protectedTerms` are the user's own spellings (dictionary replacements). A recipe
    /// may restructure: its length is free and list markers are not numbers.
    public static func violation(
        original: String, candidate: String, protectedTerms: [String] = [], allowsRestructuring: Bool = false
    ) -> Violation? {
        var candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .empty }
        if allowsRestructuring { candidate = strippingListMarkers(candidate) }
        if numbers(in: original) != numbers(in: candidate) { return .numbers }
        if identifiers(in: original) != identifiers(in: candidate) { return .identifiers }
        for term in protectedTerms where containsWord(term, in: original, caseSensitive: false) {
            if !containsWord(term, in: candidate, caseSensitive: true) { return .protectedTerm }
        }
        if negationMarkers(in: original) != negationMarkers(in: candidate) { return .negation }
        let ratio = Double(words(in: candidate).count) / Double(max(words(in: original).count, 1))
        if !allowsRestructuring, ratio < minimumLengthRatio || ratio > maximumLengthRatio { return .length }
        if startsWithPreamble(candidate) && !startsWithPreamble(original) { return .preamble }
        if let before = dominantLanguage(of: original), let after = dominantLanguage(of: candidate),
           before != after {
            return .language
        }
        return nil
    }

    /// Digit runs with their grouping removed, so "1,000" and "1000" compare equal.
    static func numbers(in text: String) -> [String] {
        matches(of: #"\d(?:[\d.,:/]*\d)?"#, in: text)
            .map { $0.filter(\.isNumber) }
            .sorted()
    }

    /// URLs, emails, @mentions and #tags must survive byte for byte.
    static func identifiers(in text: String) -> [String] {
        let pattern = #"(?:https?://|www\.)[^\s]+[^\s.,;:!?)\]]"#
            + #"|[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#
            + #"|(?<![\w@])[@#][\p{L}\p{N}_]+"#
        return matches(of: pattern, in: text).sorted()
    }

    /// "1. ", "2) " or "- " at a line start: list structure a recipe may add.
    static func strippingListMarkers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?m)^[ \t]*(?:\d{1,2}[.)]|[-*\x{2022}])[ \t]+"#, with: "", options: .regularExpression)
    }

    static func negationMarkers(in text: String) -> Set<String> {
        var markers = Set<String>()
        for word in words(in: text) {
            if word.hasSuffix("n't") || word == "cannot" {
                markers.insert("not")
            } else if negations.contains(word) {
                markers.insert(word)
            }
        }
        return markers
    }

    public static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    private static func containsWord(_ term: String, in text: String, caseSensitive: Bool) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trimmed) + "(?![\\p{L}\\p{N}])"
        var options: String.CompareOptions = [.regularExpression]
        if !caseSensitive { options.insert(.caseInsensitive) }
        return text.range(of: pattern, options: options) != nil
    }

    private static func startsWithPreamble(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return preambles.contains { lowered.hasPrefix($0) }
    }

    /// Only a long, clearly single-language text has a language to keep; code-switched
    /// dictation stays below the confidence bar and is never refused for it.
    private static func dominantLanguage(of text: String) -> NLLanguage? {
        guard text.filter(\.isLetter).count >= languageCheckMinimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= languageConfidence else { return nil }
        return language
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
