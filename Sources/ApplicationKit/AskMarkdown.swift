import Foundation

/// Formats a palette answer as Markdown for ⌘C — the answer plus its
/// citations, so a pasted response never loses its receipts.
public enum AskMarkdown {
    public static func format(
        question: String, answer: String, citations: [AskCitation]
    ) -> String {
        format(question: question, answer: answer, sources: citations.map { ($0, nil) })
    }

    /// Each citation led by who said it, when known.
    public static func format(
        question: String, answer: String, sources: [(citation: AskCitation, speaker: String?)]
    ) -> String {
        var lines = ["> \(question)", "", answer]
        if !sources.isEmpty {
            lines.append("")
            for (citation, speaker) in sources {
                let lead = speaker.map { "\($0) · " } ?? ""
                lines.append("- \(lead)\(citation.meetingTitle) · \(clock(citation.timestamp))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
