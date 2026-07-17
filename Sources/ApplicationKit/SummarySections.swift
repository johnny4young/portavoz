import Foundation
import PortavozCore

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
        /// Exact Markdown bullet lines, in display order. Typed decision
        /// evidence addresses this stable ordinal rather than matching text.
        public let bulletLines: [String]
        public var id: String { heading }
    }

    /// Prose before the first `##` header (the overview / lede).
    public let intro: String
    public let sections: [Section]

    public static func parse(_ markdown: String) -> SummarySections {
        let outline = SummaryMarkdownOutline.parse(markdown)
        return SummarySections(
            intro: outline.intro,
            sections: outline.sections.map {
                Section(
                    heading: $0.heading,
                    body: $0.body,
                    bulletCount: $0.bulletLines.count,
                    bulletLines: $0.bulletLines)
            })
    }
}
