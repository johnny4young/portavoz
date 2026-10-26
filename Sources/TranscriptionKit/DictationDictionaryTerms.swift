import Foundation

/// One spelling the user wants and every heard form that becomes it. Aliases are rules
/// that share a replacement, so storage, import and export stay plain trigger pairs.
public struct DictationTerm: Equatable, Sendable {
    public let replacement: String
    public let heard: [String]

    public init(replacement: String, heard: [String]) {
        self.replacement = replacement
        self.heard = heard
    }
}

public extension DictationTextRules {
    static let learnableHeardWords = 4
    static let learnableReplacementLength = 80

    /// Rules grouped by their exact replacement, in the order each term first appears.
    static func terms(_ replacements: [DictationReplacement]) -> [DictationTerm] {
        var order: [String] = []
        var heard: [String: [String]] = [:]
        for rule in canonical(replacements) {
            if heard[rule.replacement] == nil { order.append(rule.replacement) }
            heard[rule.replacement, default: []].append(rule.trigger)
        }
        return order.map { DictationTerm(replacement: $0, heard: heard[$0] ?? []) }
    }

    /// The rules with `heard` written as `replacement`, replacing any rule for that heard
    /// form; nil when it is already known or too long, empty or multi-line to be a term.
    static func learning(
        _ heard: String, as replacement: String, into rules: [DictationReplacement]
    ) -> [DictationReplacement]? {
        let trigger = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let spelling = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trigger.split(whereSeparator: \.isWhitespace)
        guard trigger.unicodeScalars.filter(CharacterSet.letters.contains).count >= 2,
              words.count <= learnableHeardWords,
              !spelling.isEmpty, spelling.count <= learnableReplacementLength,
              !trigger.contains(where: \.isNewline), !spelling.contains(where: \.isNewline),
              trigger != spelling else { return nil }
        let current = canonical(rules)
        let isSameTrigger = { (rule: DictationReplacement) in
            rule.trigger.compare(trigger, options: .caseInsensitive) == .orderedSame
        }
        guard !current.contains(where: { isSameTrigger($0) && $0.replacement == spelling }) else { return nil }
        return current.filter { !isSameTrigger($0) } + [DictationReplacement(trigger: trigger, replacement: spelling)]
    }
}
