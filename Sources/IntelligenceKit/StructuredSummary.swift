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
            // Models sometimes narrate the action items as a section despite
            // the schema note; the canonical block below already owns them,
            // so an action-items-shaped section would only duplicate.
            if !actionItems.isEmpty, Self.isActionItemsHeading(section.heading) { continue }
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

    /// Headings that mean "action items" in the languages the app ships:
    /// those sections duplicate the canonical block and are skipped.
    static func isActionItemsHeading(_ heading: String) -> Bool {
        let normalized = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "action items", "action item", "pendientes", "next steps",
            "to-dos", "todos", "tareas", "tareas pendientes"
        ].contains(normalized)
    }

    /// Inverse of `markdown(recipe:)` for snapshots WE rendered (every
    /// stored summary goes through that renderer, so the format is ours).
    /// The "## Action Items" block parses into `actionItems` — text and
    /// owner label split on the renderer's " — " — never into a section.
    /// Returns nil only when the text has none of the renderer's shape.
    public static func parse(markdown: String) -> StructuredSummary? {
        var overviewLines: [String] = []
        var sections: [Section] = []
        var items: [Item] = []
        var current: Section?
        var inActionItems = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if let current { sections.append(current) }
                let heading = String(line.dropFirst(3))
                inActionItems = heading.caseInsensitiveCompare("Action Items") == .orderedSame
                current = inActionItems ? nil : Section(heading: heading, bullets: [])
            } else if inActionItems, line.hasPrefix("- ") {
                var text = String(line.dropFirst(2))
                for box in ["[ ] ", "[x] "] where text.hasPrefix(box) {
                    text = String(text.dropFirst(box.count))
                }
                if let range = text.range(of: " — ", options: .backwards) {
                    items.append(
                        Item(
                            text: String(text[..<range.lowerBound]),
                            owner: String(text[range.upperBound...])))
                } else {
                    items.append(Item(text: text))
                }
            } else if line.hasPrefix("- "), current != nil {
                current?.bullets.append(String(line.dropFirst(2)))
            } else if current == nil, !inActionItems, !line.isEmpty {
                overviewLines.append(line)
            }
        }
        if let current { sections.append(current) }

        let overview = overviewLines.joined(separator: " ")
        guard !overview.isEmpty || !sections.isEmpty else { return nil }
        return StructuredSummary(overview: overview, sections: sections, actionItems: items)
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
