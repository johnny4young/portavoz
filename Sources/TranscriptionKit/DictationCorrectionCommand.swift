import Foundation

/// A spoken correction of the last insertion. Parsing is deterministic and bilingual;
/// a phrase is a command only when what it names is in the text it would correct.
public enum DictationCorrectionCommand: Equatable, Sendable {
    case replace(String, with: String)
    case delete(String)
    case deleteLast

    /// The span of `inserted` to replace, and its replacement; nil when the command does
    /// not apply, so the dictation is ordinary text after all.
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
    }

    // Escaped so the English-source guard does not read them as Spanish prose.
    static let deleteLastPhrases: Set<String> = [
        "scratch that", "delete that", "undo that", "remove that",
        "borra eso", "borra lo \u{FA}ltimo", "borra lo ultimo", "b\u{F3}rralo", "borralo", "deshaz eso"
    ]
    private static let replacePatterns = [
        #"^(?:change|replace)\s+(.+?)\s+(?:to|with)\s+(.+)$"#,
        #"^(?:cambia|reemplaza|sustituye)\s+(.+?)\s+por\s+(.+)$"#
    ]
    private static let deletePatterns = [
        #"^(?:delete|remove)\s+(.+)$"#,
        #"^(?:borra|elimina|quita)\s+(.+)$"#
    ]

    public static func parse(_ spoken: String) -> Self? {
        let text = normalized(spoken)
        guard !text.isEmpty else { return nil }
        if deleteLastPhrases.contains(text.lowercased()) { return .deleteLast }
        for pattern in replacePatterns {
            if let groups = captures(pattern, in: text), groups.count == 2 {
                return .replace(groups[0], with: groups[1])
            }
        }
        for pattern in deletePatterns {
            if let groups = captures(pattern, in: text), groups.count == 1 { return .delete(groups[0]) }
        }
        return nil
    }

    /// The last whole-word occurrence wins: the user usually corrects what they just said.
    public func edit(in inserted: String) -> Edit? {
        switch self {
        case .deleteLast:
            return Edit(range: NSRange(location: 0, length: inserted.utf16.count), replacement: "")
        case .replace(let target, let replacement):
            guard let range = Self.lastWholeWord(target, in: inserted) else { return nil }
            return Edit(range: range, replacement: Self.matchingCase(of: inserted, at: range, for: replacement))
        case .delete(let target):
            guard let range = Self.lastWholeWord(target, in: inserted) else { return nil }
            return Edit(range: Self.includingOneSpace(range, in: inserted), replacement: "")
        }
    }

    /// Recognizers add sentence punctuation and capitals the command never meant.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
            Range(match.range(at: index), in: text).map { normalized(String(text[$0])) }
        }
        return groups.allSatisfy { !$0.isEmpty } ? groups : nil
    }

    private static func lastWholeWord(_ target: String, in text: String) -> NSRange? {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: target) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last?.range
    }

    /// "Friday" corrected to "monday" keeps the capital the text already had.
    private static func matchingCase(of text: String, at range: NSRange, for replacement: String) -> String {
        guard let swiftRange = Range(range, in: text), let first = text[swiftRange].first, first.isUppercase,
              let head = replacement.first else { return replacement }
        return head.uppercased() + replacement.dropFirst()
    }

    /// Deleting a word also takes one neighboring space, so no double space is left.
    private static func includingOneSpace(_ range: NSRange, in text: String) -> NSRange {
        let utf16 = Array(text.utf16)
        let end = range.location + range.length
        if end < utf16.count, utf16[end] == 0x20 { return NSRange(location: range.location, length: range.length + 1) }
        if range.location > 0, utf16[range.location - 1] == 0x20 {
            return NSRange(location: range.location - 1, length: range.length + 1)
        }
        return range
    }
}
