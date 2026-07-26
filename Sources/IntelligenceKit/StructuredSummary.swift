import Foundation
import PortavozCore

/// Provider-neutral shape of a generated summary. Foundation Models maps
/// its guided-generation output here; BYOK providers decode JSON into it.
/// Everything downstream (markdown, action-item owners) is shared.
public struct StructuredSummary: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable {
        public var heading: String
        public var bullets: [String]
        /// One exact E-tag list per bullet. Optional keeps responses created
        /// before typed decision evidence decodable.
        public var bulletEvidence: [[String]]?

        public init(
            heading: String,
            bullets: [String],
            bulletEvidence: [[String]]? = nil
        ) {
            self.heading = heading
            self.bullets = bullets
            self.bulletEvidence = bulletEvidence
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        /// Speaker label as spoken in the transcript ("Me", "S1", a name);
        /// empty when ownership wasn't stated.
        public var owner: String
        /// Exact request-local E-tags supporting this commitment.
        public var evidence: [String]?

        public init(text: String, owner: String = "", evidence: [String]? = nil) {
            self.text = text
            self.owner = owner
            self.evidence = evidence
        }
    }

    public var overview: String
    public var sections: [Section]
    public var actionItems: [Item]
    /// Compact transcript tags (E1, E2, …) supporting only the overview.
    /// Optional keeps older provider responses and local fixtures decodable.
    public var overviewEvidence: [String]?

    public init(
        overview: String,
        sections: [Section],
        actionItems: [Item],
        overviewEvidence: [String]? = nil
    ) {
        self.overview = overview
        self.sections = sections
        self.actionItems = actionItems
        self.overviewEvidence = overviewEvidence
    }
}

extension StructuredSummary {
    /// Renders the canonical markdown snapshot for a `SummaryDraft`. The
    /// output language localizes the one heading WE write (the canonical
    /// action-items block) — every other heading arrives already translated
    /// by the model. `parse` reads back exactly the two headings written
    /// here; `isActionItemsHeading` below is the deliberately broader set
    /// used only to drop a model-narrated duplicate section while
    /// rendering.
    public func markdown(recipe: Recipe, language: String? = nil) -> String {
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
            let heading = language?.lowercased().hasPrefix("es") == true
                ? "Pendientes" : "Action Items"
            var block = "## \(heading)"
            for item in actionItems {
                let owner = item.owner.isEmpty ? "" : " — \(item.owner)"
                block += "\n- [ ] \(item.text)\(owner)"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Headings that mean "action items" in the languages the app ships:
    /// those sections duplicate the canonical block and are skipped. Public
    /// because the recap composer drops the same sections for the same
    /// reason — it re-renders commitments from the library's real done state.
    public static func isActionItemsHeading(_ heading: String) -> Bool {
        let normalized = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "action items", "action item", "pendientes", "next steps",
            "to-dos", "todos", "tareas", "tareas pendientes"
        ].contains(normalized)
    }

    /// Inverse of `markdown(recipe:language:)` for snapshots WE rendered
    /// (every stored summary goes through that renderer, so the format is
    /// ours). The canonical block — "## Action Items" or its Spanish
    /// "## Pendientes" — parses into `actionItems`, text and owner label
    /// split on the renderer's " — ", never into a section.
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
                // Only the two headings OUR renderer emits for the canonical
                // block — the broader isActionItemsHeading set would swallow
                // a real "Next Steps" section on re-parse.
                inActionItems = heading.caseInsensitiveCompare("Action Items") == .orderedSame
                    || heading.caseInsensitiveCompare("Pendientes") == .orderedSame
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
        for request: SummaryRequest,
        includeEvidence: Bool = true
    ) -> SummaryDraft {
        var admitted = self
        let groundedActions = SummaryActionAdmission.admittedItems(
            actionItems,
            sections: sections,
            recipe: request.recipe)
            .compactMap { Self.groundedAction($0, speakers: request.speakers) }
        admitted.actionItems = groundedActions.map(\.item)
        let items = groundedActions.map {
            ActionItem(text: $0.item.text, ownerSpeakerID: $0.ownerSpeakerID)
        }
        let evidence = TranscriptFormatter.formatWithEvidence(
            segments: request.segments,
            speakers: request.speakers)
        let segmentsByID = Dictionary(
            request.segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let resolvedOverviewIDs = includeEvidence
            ? TranscriptFormatter.resolveEvidenceTags(
                admitted.overviewEvidence ?? [], segmentIDsByTag: evidence.segmentIDsByTag)
            : []
        let evidenceIDs = SummaryEvidenceAdmission.validatedSegmentIDs(
            for: admitted.overview,
            candidateIDs: resolvedOverviewIDs,
            segmentsByID: segmentsByID)
        let claims = evidenceIDs.isEmpty
            || admitted.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [SummaryClaim(kind: .overview, evidenceSegmentIDs: evidenceIDs)]
        let decisions = admitted.typedDecisionEvidence(
            for: request,
            segmentIDsByTag: evidence.segmentIDsByTag,
            segmentsByID: segmentsByID,
            includeEvidence: includeEvidence)
        let actionEvidence = admitted.typedActionItemEvidence(
            items: items,
            segmentIDsByTag: evidence.segmentIDsByTag,
            segmentsByID: segmentsByID,
            includeEvidence: includeEvidence)
        return SummaryDraft(
            meetingID: request.meetingID,
            recipeID: request.recipe.id,
            language: request.targetLanguage,
            markdown: admitted.markdown(
                recipe: request.recipe, language: request.targetLanguage),
            actionItems: items,
            claims: claims,
            decisionEvidence: decisions,
            actionItemEvidence: actionEvidence
        )
    }

    private struct GroundedAction {
        let item: Item
        let ownerSpeakerID: SpeakerID?
    }

    /// Generated owner strings are untrusted. Exact labels take precedence;
    /// a display name is admitted only when it uniquely identifies one cast
    /// member. Carry the resolved ID beside the rendered value so typed
    /// projection never re-resolves an ambiguous canonical name.
    private static func groundedAction(
        _ item: Item,
        speakers: [Speaker]
    ) -> GroundedAction? {
        let rawOwner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = matchedSpeaker(for: rawOwner, speakers: speakers)
        var admitted = item
        admitted.text = strippingOwnerPrefix(from: item.text, owner: rawOwner)
        admitted.owner = speaker.map { speaker in
            if let displayName = speaker.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !displayName.isEmpty {
                return displayName
            }
            return speaker.label
        } ?? ""
        guard !admitted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return GroundedAction(item: admitted, ownerSpeakerID: speaker?.id)
    }

    private static func matchedSpeaker(
        for owner: String,
        speakers: [Speaker]
    ) -> Speaker? {
        guard !owner.isEmpty else { return nil }
        let labelMatches = speakers.filter {
            $0.label.caseInsensitiveCompare(owner) == .orderedSame
        }
        if labelMatches.count == 1 {
            return labelMatches[0]
        }
        guard labelMatches.isEmpty else { return nil }
        let nameMatches = speakers.filter {
            $0.displayName?.caseInsensitiveCompare(owner) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private static func strippingOwnerPrefix(from text: String, owner: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return trimmed }
        for separator in [":", " —", " -"] {
            let prefix = owner + separator
            guard trimmed.range(
                of: prefix,
                options: [.anchored, .caseInsensitive]) != nil
            else { continue }
            return trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func typedActionItemEvidence(
        items: [ActionItem],
        segmentIDsByTag: [String: UUID],
        segmentsByID: [UUID: TranscriptSegment],
        includeEvidence: Bool
    ) -> [SummaryActionItemEvidence] {
        guard includeEvidence, items.count == actionItems.count else { return [] }
        return zip(items, actionItems).compactMap { item, structured -> SummaryActionItemEvidence? in
            let ids = TranscriptFormatter.resolveEvidenceTags(
                structured.evidence ?? [],
                segmentIDsByTag: segmentIDsByTag)
            let validatedIDs = SummaryEvidenceAdmission.validatedSegmentIDs(
                for: structured.text,
                candidateIDs: ids,
                segmentsByID: segmentsByID)
            guard !validatedIDs.isEmpty else { return nil }
            return SummaryActionItemEvidence(
                actionItemID: item.id,
                evidenceSegmentIDs: validatedIDs)
        }
    }

    private func typedDecisionEvidence(
        for request: SummaryRequest,
        segmentIDsByTag: [String: UUID],
        segmentsByID: [UUID: TranscriptSegment],
        includeEvidence: Bool
    ) -> [SummaryDecisionEvidence] {
        guard includeEvidence,
              sections.count == request.recipe.sections.count,
              !request.recipe.decisionSectionIndexes.isEmpty
        else { return [] }

        var result: [SummaryDecisionEvidence] = []
        var renderedSectionOrdinal = 0
        for (sectionIndex, section) in sections.enumerated() where !section.bullets.isEmpty {
            if !actionItems.isEmpty, Self.isActionItemsHeading(section.heading) { continue }
            defer { renderedSectionOrdinal += 1 }
            guard request.recipe.decisionSectionIndexes.contains(sectionIndex),
                  let bulletEvidence = section.bulletEvidence,
                  bulletEvidence.count == section.bullets.count
            else { continue }
            for (bulletOrdinal, tags) in bulletEvidence.enumerated() {
                let ids = TranscriptFormatter.resolveEvidenceTags(
                    tags,
                    segmentIDsByTag: segmentIDsByTag)
                let validatedIDs = SummaryEvidenceAdmission.validatedSegmentIDs(
                    for: section.bullets[bulletOrdinal],
                    candidateIDs: ids,
                    segmentsByID: segmentsByID)
                guard !validatedIDs.isEmpty else { continue }
                result.append(SummaryDecisionEvidence(
                    sectionOrdinal: renderedSectionOrdinal,
                    bulletOrdinal: bulletOrdinal,
                    evidenceSegmentIDs: validatedIDs))
            }
        }
        return result
    }

    /// Translation preserves typed evidence only when the rendered section
    /// and bullet coordinate still exists after positional validation.
    static func translatedDecisionEvidence(
        from pivot: SummaryDraft,
        into sections: [Section]
    ) -> [SummaryDecisionEvidence] {
        pivot.decisionEvidence.compactMap { decision in
            guard sections.indices.contains(decision.sectionOrdinal),
                  sections[decision.sectionOrdinal].bullets.indices.contains(
                    decision.bulletOrdinal)
            else { return nil }
            return SummaryDecisionEvidence(
                sectionOrdinal: decision.sectionOrdinal,
                bulletOrdinal: decision.bulletOrdinal,
                sourceTranscriptRevision: decision.sourceTranscriptRevision,
                evidenceSegmentIDs: decision.evidenceSegmentIDs,
                unavailableEvidenceCount: decision.unavailableEvidenceCount)
        }
    }

    /// Action items receive fresh IDs on translation; evidence follows the
    /// corresponding item position rather than a rendered Markdown section.
    static func translatedActionItemEvidence(
        from pivot: SummaryDraft,
        into items: [ActionItem]
    ) -> [SummaryActionItemEvidence] {
        guard pivot.actionItems.count == items.count else { return [] }
        let evidenceByItem = pivot.actionItemEvidence.reduce(
            into: [UUID: SummaryActionItemEvidence]()
        ) { result, evidence in
            if result[evidence.actionItemID] == nil {
                result[evidence.actionItemID] = evidence
            }
        }
        return zip(pivot.actionItems, items).compactMap { oldItem, newItem in
            guard let evidence = evidenceByItem[oldItem.id] else { return nil }
            return SummaryActionItemEvidence(
                actionItemID: newItem.id,
                sourceTranscriptRevision: evidence.sourceTranscriptRevision,
                evidenceSegmentIDs: evidence.evidenceSegmentIDs,
                unavailableEvidenceCount: evidence.unavailableEvidenceCount)
        }
    }
}
