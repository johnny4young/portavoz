/// Spacing between dictated text and the text around the caret. Only
/// separators are ever added; the dictated words themselves never change.
enum DictationCaretJoin {
    // Escaped so the English-source guard does not read them as Spanish prose.
    private static let opensText: Set<Character> = [
        "(", "[", "{", "\u{BF}", "\u{A1}", "“", "‘", "«", "/", "@", "#"
    ]
    private static let attachesLeft: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "»", "”", "’", "…", "%"
    ]

    /// - Parameters:
    ///   - preceding: the text just before the selection; nil when it is unknown.
    ///   - following: the text just after the selection; nil when it is unknown.
    static func join(_ text: String, after preceding: String?, before following: String? = nil) -> String {
        leading(text, after: preceding) + text + trailing(text, before: following)
    }

    private static func leading(_ text: String, after preceding: String?) -> String {
        guard let preceding, let last = preceding.last, let first = text.first,
              !last.isWhitespace, !opensText.contains(last), !opensStraightQuote(preceding),
              !first.isWhitespace, !attachesLeft.contains(first) else { return "" }
        return " "
    }

    /// A word right after the caret is pushed apart; punctuation keeps attaching to it.
    private static func trailing(_ text: String, before following: String?) -> String {
        guard let next = following?.first, next.isLetter || next.isNumber,
              let last = text.last, !last.isWhitespace, !opensText.contains(last) else { return "" }
        return " "
    }

    /// A straight quote opens text when nothing but whitespace precedes it.
    private static func opensStraightQuote(_ preceding: String) -> Bool {
        guard let last = preceding.last, last == "\"" || last == "'" else { return false }
        return preceding.dropLast().last.map(\.isWhitespace) ?? true
    }
}
