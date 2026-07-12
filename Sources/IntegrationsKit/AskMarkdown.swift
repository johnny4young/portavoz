import Foundation
import IntelligenceKit

/// Formats a palette answer as Markdown for ⌘C — the answer plus its
/// citations, so a pasted response never loses its receipts.
public enum AskMarkdown {
    public static func format(
        question: String, answer: String, passages: [RAGPassage]
    ) -> String {
        var lines = ["> \(question)", "", answer]
        if !passages.isEmpty {
            lines.append("")
            for passage in passages {
                lines.append("- \(passage.meetingTitle) · \(clock(passage.timestamp))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
