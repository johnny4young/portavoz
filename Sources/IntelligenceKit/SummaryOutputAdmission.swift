import Foundation
import PortavozCore

/// Deterministic last-mile gates for model output. Provider-owned E-tags prove
/// identity, not relevance; durable evidence must also share distinctive
/// lexical material with the claim it purports to support.
enum SummaryEvidenceAdmission {
    private static let stopWords: Set<String> = [
        "about", "agreed", "meeting", "project", "team", "their", "there", "which",
        "acordo", "acordó", "equipo", "proyecto", "reunion", "reunión", "sobre"
    ]

    static func validatedSegmentIDs(
        for statement: String,
        candidateIDs: [UUID],
        segmentsByID: [UUID: TranscriptSegment]
    ) -> [UUID] {
        candidateIDs.filter { id in
            guard let segment = segmentsByID[id] else { return false }
            return isGrounded(statement, in: segment.text)
        }
    }

    static func isGrounded(_ statement: String, in evidence: String) -> Bool {
        let statementTokens = distinctiveTokens(in: statement)
        guard !statementTokens.isEmpty else { return false }
        return !statementTokens.isDisjoint(with: distinctiveTokens(in: evidence))
    }

    private static func distinctiveTokens(in text: String) -> Set<String> {
        Set(normalizedTokens(in: text).filter { token in
            let numeric = token.allSatisfy(\.isNumber)
            return numeric || (token.count >= 5 && !stopWords.contains(token))
        })
    }

    static func normalizedComparableText(_ text: String) -> String {
        normalizedTokens(in: text).joined(separator: " ")
    }

    private static func normalizedTokens(in text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// A model can describe the same fact as both a decision and a task. Exact
/// copies are not actionable work and are rejected before markdown, task rows,
/// or evidence receive durable identities.
enum SummaryActionAdmission {
    static func admittedItems(
        _ items: [StructuredSummary.Item],
        sections: [StructuredSummary.Section],
        recipe: Recipe
    ) -> [StructuredSummary.Item] {
        let decisionCopies = normalizedDecisionBullets(sections: sections, recipe: recipe)
        var seen: Set<String> = []
        return items.filter { item in
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = SummaryEvidenceAdmission.normalizedComparableText(trimmed)
            guard TranscriptContentPolicy.hasLexicalContent(trimmed), !normalized.isEmpty else {
                return false
            }
            guard seen.insert(normalized).inserted else { return false }
            return !decisionCopies.contains(normalized)
        }
    }

    private static func normalizedDecisionBullets(
        sections: [StructuredSummary.Section],
        recipe: Recipe
    ) -> Set<String> {
        guard sections.count == recipe.sections.count else { return [] }
        return Set(sections.enumerated().flatMap { index, section -> [String] in
            guard recipe.decisionSectionIndexes.contains(index) else { return [] }
            return section.bullets.map(SummaryEvidenceAdmission.normalizedComparableText)
        }.filter { !$0.isEmpty })
    }
}
