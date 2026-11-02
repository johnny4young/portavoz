import Foundation

/// Separates the private `<think>` / `<thinking>` reasoning that local and
/// hosted models may emit from the answer they actually return.
enum ReasoningEnvelope {
    private static let closedBlock = try? NSRegularExpression(
        pattern: #"<think(?:ing)?(?:\s[^>]*)?>.*?</think(?:ing)?\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let closingTag = try? NSRegularExpression(
        pattern: #"</think(?:ing)?\s*>"#, options: .caseInsensitive)
    private static let openingTag = try? NSRegularExpression(
        pattern: #"<think(?:ing)?(?:\s[^>]*)?>"#, options: .caseInsensitive)

    /// The answer without reasoning, or nil when a reasoning block never
    /// closed. A lone closing tag means the chat template opened the block,
    /// so everything before it is reasoning too.
    static func visibleText(_ text: String) -> String? {
        var visible = text
        if let closedBlock {
            visible = closedBlock.stringByReplacingMatches(
                in: visible, range: NSRange(visible.startIndex..., in: visible), withTemplate: "")
        }
        if let lastClose = closingTag?
            .matches(in: visible, range: NSRange(visible.startIndex..., in: visible)).last,
            let range = Range(lastClose.range, in: visible) {
            visible = String(visible[range.upperBound...])
        }
        if openingTag?.firstMatch(in: visible, range: NSRange(visible.startIndex..., in: visible)) != nil {
            return nil
        }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
