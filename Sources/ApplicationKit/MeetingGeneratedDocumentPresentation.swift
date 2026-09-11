import Foundation

/// Pure projection of one generated meeting document for review UI.
///
/// The generated Markdown can contain the canonical action-item appendix that
/// is also persisted as typed `ActionItem` values. Review surfaces must show
/// that material once, through the typed commitment controls, while retaining
/// every recipe-authored section (including similarly named custom sections).
public struct MeetingGeneratedDocumentPresentation: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        /// Ordinal in the unfiltered Markdown outline. Typed evidence uses
        /// this value, not the section's visual position after filtering.
        public let sourceOrdinal: Int
        public let heading: String
        public let body: String
        public let bulletCount: Int
        public let bulletLines: [String]

        public var id: Int { sourceOrdinal }
    }

    public let overviewMarkdown: String
    public let sections: [Section]
    public let canonicalCommitmentSectionCount: Int

    public init(markdown: String, hasTypedCommitments: Bool) {
        let parsed = SummarySections.parse(markdown)
        overviewMarkdown = parsed.sections.isEmpty && parsed.intro.isEmpty
            ? markdown
            : parsed.intro

        var canonicalCommitmentSectionCount = 0
        sections = parsed.sections.enumerated().compactMap { ordinal, section in
            guard !(hasTypedCommitments
                && Self.isCanonicalCommitmentHeading(section.heading)) else {
                canonicalCommitmentSectionCount += 1
                return nil
            }
            return Section(
                sourceOrdinal: ordinal,
                heading: section.heading,
                body: section.body,
                bulletCount: section.bulletCount,
                bulletLines: section.bulletLines)
        }
        self.canonicalCommitmentSectionCount = canonicalCommitmentSectionCount
    }

    private static func isCanonicalCommitmentHeading(_ heading: String) -> Bool {
        switch heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "action items", "pendientes": true
        default: false
        }
    }
}
