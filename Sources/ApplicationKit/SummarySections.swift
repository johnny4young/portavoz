import Foundation

/// Splits a summary's Markdown into its intro and `##`-delimited sections
/// so the detail view can tab through them (design system: Resumen ·
/// Decisiones · Preguntas). Header-agnostic — it keys off `##`, not the
/// section NAMES, so it works whatever language the summary is in.
public struct SummarySections: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let heading: String
        public let body: String
        /// Bullet lines in this section — the count the tab badge shows.
        public let bulletCount: Int
        public var id: String { heading }
    }

    /// Prose before the first `##` header (the overview / lede).
    public let intro: String
    public let sections: [Section]

    public static func parse(_ markdown: String) -> SummarySections {
        var intro: [String] = []
        var sections: [Section] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .newlines)
            sections.append(
                Section(heading: heading, body: body, bulletCount: bulletCount(in: currentBody)))
            currentBody = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# ") {
                // A top-level H1 title is chrome, not a section — skip it.
                continue
            } else if currentHeading == nil {
                intro.append(line)
            } else {
                currentBody.append(line)
            }
        }
        flush()

        return SummarySections(
            intro: intro.joined(separator: "\n").trimmingCharacters(in: .newlines),
            sections: sections)
    }

    /// Counts bullet lines (`-`, `*`, `·`, or `▸` co-authored markers).
    private static func bulletCount(in lines: [String]) -> Int {
        lines.reduce(0) { count, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let markers = ["- ", "* ", "· ", "▸ "]
            return markers.contains(where: trimmed.hasPrefix) ? count + 1 : count
        }
    }
}
