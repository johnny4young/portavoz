import CoreGraphics
import CoreText
import Foundation
import PortavozCore

/// Renders a meeting into shareable documents (L0 of the sharing ladder,
/// D12). Markdown is the canonical open format; the PDF is typeset from
/// that same markdown with CoreText — no AppKit, so it works on iOS too.
public enum MeetingExporter {
    // MARK: - Markdown

    public static func markdown(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft? = nil,
        summaryVersion: Int? = nil
    ) -> String {
        var parts: [String] = ["# \(meeting.title)"]

        var facts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let ended = meeting.endedAt {
            facts.append("\(max(1, Int(ended.timeIntervalSince(meeting.startedAt) / 60))) min")
        }
        if !speakers.isEmpty {
            facts.append("\(speakers.count) hablante(s)")
        }
        facts.append("transcrito localmente por Portavoz")
        parts.append("> " + facts.joined(separator: " · "))

        if let summary {
            let versionTag = summaryVersion.map { " (v\($0) · \(summary.language))" } ?? " (\(summary.language))"
            var block = "## Resumen\(versionTag)\n\n"
            block += demoteHeadings(in: summary.markdown)
            if !summary.actionItems.isEmpty {
                block += "\n\n### Pendientes\n"
                let labelsByID = Dictionary(
                    uniqueKeysWithValues: speakers.map { ($0.id, displayName($0)) })
                for item in summary.actionItems {
                    let mark = item.isDone ? "x" : " "
                    let owner = item.ownerSpeakerID.flatMap { labelsByID[$0] }.map { " — \($0)" } ?? ""
                    block += "- [\(mark)] \(item.text)\(owner)\n"
                }
            }
            parts.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !segments.isEmpty {
            let labelsByID = Dictionary(
                uniqueKeysWithValues: speakers.map { ($0.id, displayName($0)) })
            var block = "## Transcript\n"
            for segment in segments {
                let label = segment.speakerID.flatMap { labelsByID[$0] } ?? "¿?"
                block += "\n- **[\(timestamp(segment.startTime))] \(label):** \(segment.text)"
            }
            parts.append(block)
        }

        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The summary's own `##` headings become `###` so they nest under
    /// the document's "## Resumen" section instead of colliding with it.
    static func demoteHeadings(in markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("## ") ? "#\($0)" : String($0) }
            .joined(separator: "\n")
    }

    static func displayName(_ speaker: Speaker) -> String {
        speaker.displayName ?? speaker.label
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Summary copy (plain text / Markdown / Slack mrkdwn)

    public enum SummaryFormat: String, CaseIterable, Sendable {
        case plainText
        case markdown
        case slack
    }

    /// The summary (overview + sections + pending items) rendered for the
    /// clipboard. Markdown is canonical; plain text strips syntax; Slack uses
    /// mrkdwn (`*bold*`, `•` bullets, no `#` headings — what Slack renders).
    public static func summary(
        _ summary: SummaryDraft,
        speakers: [Speaker] = [],
        format: SummaryFormat
    ) -> String {
        var markdown = summary.markdown
        if !summary.actionItems.isEmpty {
            let labelsByID = Dictionary(
                uniqueKeysWithValues: speakers.map { ($0.id, displayName($0)) })
            markdown += "\n\n## Pendientes\n"
            for item in summary.actionItems {
                let mark = item.isDone ? "x" : " "
                let owner = item.ownerSpeakerID.flatMap { labelsByID[$0] }.map { " — \($0)" } ?? ""
                markdown += "- [\(mark)] \(item.text)\(owner)\n"
            }
        }
        markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .markdown: return markdown + "\n"
        case .plainText: return renderLines(markdown, slack: false)
        case .slack: return renderLines(markdown, slack: true)
        }
    }

    /// Line-by-line rewrite of the summary markdown. Plain text drops every
    /// marker; Slack keeps emphasis as mrkdwn. Both turn `#` headings and
    /// `-`/`▸` bullets into readable lines (Slack renders neither `#` nor `[ ]`).
    private static func renderLines(_ markdown: String, slack: Bool) -> String {
        var out: [String] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Headings: `## Text` → bold (Slack) or bare text (plain).
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#") {
                let text = trimmed[hashes...].trimmingCharacters(in: .whitespaces)
                out.append(slack ? "*\(inlines(text, slack: true))*" : inlines(text, slack: false))
                continue
            }

            // Checkbox list items: `- [ ] Text` / `- [x] Text`.
            if let range = trimmed.range(of: #"^[-*] \[( |x)\] "#, options: .regularExpression) {
                let done = trimmed[range].contains("x")
                let text = String(trimmed[range.upperBound...])
                let box = done ? "✓" : "☐"
                out.append("• \(box) \(inlines(text, slack: slack))")
                continue
            }

            // Plain bullets: `- Text`, `* Text`, or the coauthoring `▸ Text`.
            if let range = trimmed.range(of: #"^([-*] |▸ )"#, options: .regularExpression) {
                let text = String(trimmed[range.upperBound...])
                out.append("• \(inlines(text, slack: slack))")
                continue
            }

            line = inlines(line, slack: slack)
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Rewrites inline emphasis: plain text strips `**`/`*`/`_`; Slack folds
    /// `**bold**` into its single-star bold.
    private static func inlines(_ text: String, slack: Bool) -> String {
        if slack {
            return text.replacingOccurrences(of: "**", with: "*")
        }
        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    // MARK: - PDF (CoreText, US Letter)

    public enum ExportError: Error, LocalizedError {
        case pdfContextFailed

        public var errorDescription: String? {
            switch self {
            case .pdfContextFailed: return "could not create the PDF context"
            }
        }
    }

    /// Typesets exporter markdown into a paginated PDF.
    public static func pdf(fromMarkdown markdown: String) throws -> Data {
        try pdf(from: attributedString(fromMarkdown: markdown))
    }

    /// Minimal markdown-to-attributed mapping: `#`/`##`/`###` headings,
    /// `-` bullets and `>` metadata; everything else is body text.
    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        let body = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        let h1 = CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
        let h2 = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
        let h3 = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let gray = CGColor(gray: 0.35, alpha: 1)

        let output = NSMutableAttributedString()
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let rendered: NSAttributedString
            if line.hasPrefix("# ") {
                rendered = NSAttributedString(
                    string: String(line.dropFirst(2)) + "\n", attributes: [fontKey: h1])
            } else if line.hasPrefix("## ") {
                rendered = NSAttributedString(
                    string: "\n" + String(line.dropFirst(3)) + "\n", attributes: [fontKey: h2])
            } else if line.hasPrefix("### ") {
                rendered = NSAttributedString(
                    string: "\n" + String(line.dropFirst(4)) + "\n", attributes: [fontKey: h3])
            } else if line.hasPrefix("> ") {
                rendered = NSAttributedString(
                    string: String(line.dropFirst(2)) + "\n",
                    attributes: [fontKey: body, colorKey: gray])
            } else if line.hasPrefix("- ") {
                // Strip the transcript's own bold markers; PDF styling is ours.
                let text = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
                rendered = NSAttributedString(
                    string: "•  \(text)\n", attributes: [fontKey: body])
            } else if line.isEmpty {
                rendered = NSAttributedString(string: "\n", attributes: [fontKey: body])
            } else {
                rendered = NSAttributedString(
                    string: line.replacingOccurrences(of: "**", with: "") + "\n",
                    attributes: [fontKey: body])
            }
            output.append(rendered)
        }
        return output
    }

    static func pdf(from attributed: NSAttributedString) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        guard
            let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExportError.pdfContextFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let inset = mediaBox.insetBy(dx: 54, dy: 54)
        let path = CGPath(rect: inset, transform: nil)

        var location = 0
        while location < attributed.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        }
        context.closePDF()
        return data as Data
    }
}
