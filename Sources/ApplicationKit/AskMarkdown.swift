import Foundation

/// Formats a palette answer as Markdown for ⌘C — the answer plus its
/// citations, so a pasted response never loses its receipts.
public enum AskMarkdown {
    public static func format(
        question: String, answer: String, citations: [AskCitation]
    ) -> String {
        var lines = ["> \(question)", "", answer]
        if !citations.isEmpty {
            lines.append("")
            for citation in citations {
                lines.append("- \(citation.meetingTitle) · \(clock(citation.timestamp))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
