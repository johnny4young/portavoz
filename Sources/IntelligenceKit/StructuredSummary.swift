import Foundation
import PortavozCore

/// Provider-neutral shape of a generated summary. Foundation Models maps
/// its guided-generation output here; BYOK providers decode JSON into it.
/// Everything downstream (markdown, action-item owners) is shared.
public struct StructuredSummary: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable {
        public var heading: String
        public var bullets: [String]

        public init(heading: String, bullets: [String]) {
            self.heading = heading
            self.bullets = bullets
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        /// Speaker label as spoken in the transcript ("Me", "S1", a name);
        /// empty when ownership wasn't stated.
        public var owner: String

        public init(text: String, owner: String = "") {
            self.text = text
            self.owner = owner
        }
    }

    public var overview: String
    public var sections: [Section]
    public var actionItems: [Item]

    public init(overview: String, sections: [Section], actionItems: [Item]) {
        self.overview = overview
        self.sections = sections
        self.actionItems = actionItems
    }
}

extension StructuredSummary {
    /// Renders the canonical markdown snapshot for a `SummaryDraft`.
    public func markdown(recipe: Recipe) -> String {
        var parts: [String] = []
        let trimmedOverview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverview.isEmpty {
            parts.append(trimmedOverview)
        }
        for section in sections where !section.bullets.isEmpty {
            var block = "## \(section.heading)"
            for bullet in section.bullets {
                block += "\n- \(bullet)"
            }
            parts.append(block)
        }
        if !actionItems.isEmpty {
            var block = "## Action Items"
            for item in actionItems {
                let owner = item.owner.isEmpty ? "" : " — \(item.owner)"
                block += "\n- [ ] \(item.text)\(owner)"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Builds the final draft, resolving action-item owners against the
    /// meeting's speakers by label or display name (case-insensitive).
    public func draft(
        for request: SummaryRequest
    ) -> SummaryDraft {
        let items = actionItems.map { item -> ActionItem in
            let owner = request.speakers.first { speaker in
                speaker.label.caseInsensitiveCompare(item.owner) == .orderedSame
                    || speaker.displayName?.caseInsensitiveCompare(item.owner) == .orderedSame
            }
            return ActionItem(text: item.text, ownerSpeakerID: owner?.id)
        }
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: markdown(recipe: request.recipe),
            actionItems: items
        )
    }
}
