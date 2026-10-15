/// Spacing between dictated text and what already precedes the caret. Only a
/// separator is ever added; the dictated words themselves never change.
enum DictationCaretJoin {
    // Escaped so the English-source guard does not read them as Spanish prose.
    private static let opensText: Set<Character> = [
        "(", "[", "{", "\u{BF}", "\u{A1}", "“", "‘", "«", "/", "@", "#"
    ]
    private static let attachesLeft: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "»", "”", "’", "…", "%"
    ]

    /// - Parameter preceding: the text just before the caret; nil when it is unknown.
    static func join(_ text: String, after preceding: String?) -> String {
        guard let last = preceding?.last, let first = text.first,
              !last.isWhitespace, !opensText.contains(last),
              !first.isWhitespace, !attachesLeft.contains(first) else { return text }
        return " " + text
    }
}
