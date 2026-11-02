import Foundation

/// Separates the private `<think>` / `<thinking>` reasoning that local and
/// hosted models may emit from the answer they actually return.
enum ReasoningEnvelope {
    private static let fenceOpener = #"^\s*(?:```[A-Za-z]*\s*)?"#
    private static let open = #"<think(?:ing)?(?:\s[^>]*)?>"#
    private static let close = #"</think(?:ing)?\s*>"#
    private static let leadingBlock = try? NSRegularExpression(
        pattern: fenceOpener + "(" + open + ".*?" + close + ")",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let leadingOpen = try? NSRegularExpression(
        pattern: fenceOpener + open, options: .caseInsensitive)
    private static let openingTag = try? NSRegularExpression(pattern: open, options: .caseInsensitive)
    private static let closingTag = try? NSRegularExpression(pattern: close, options: .caseInsensitive)

    /// The answer without reasoning, or nil when a reasoning block never
    /// closed. Reasoning only precedes the answer, so tags quoted later stay.
    /// A closing tag with no opening tag before it means the chat template
    /// opened the block, so everything before it is reasoning too.
    static func visibleText(_ text: String) -> String? {
        var visible = text
        while let block = leadingBlock?.firstMatch(in: visible, range: whole(visible)),
            let range = Range(block.range(at: 1), in: visible) {
            visible.removeSubrange(range)
        }
        if leadingOpen?.firstMatch(in: visible, range: whole(visible)) != nil { return nil }
        if let close = closingTag?.firstMatch(in: visible, range: whole(visible)),
            let range = Range(close.range, in: visible),
            openingTag?.firstMatch(in: visible, range: NSRange(visible.startIndex..<range.lowerBound, in: visible))
                == nil {
            visible = String(visible[range.upperBound...])
        }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whole(_ text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }
}
