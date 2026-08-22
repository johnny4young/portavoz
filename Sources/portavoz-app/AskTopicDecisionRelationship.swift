import ApplicationKit
import Foundation
import PortavozCore

struct AskMemoryDecisionConflict: Identifiable, Equatable {
    let id: DecisionEventID
    let successorDecisionID: DecisionID
    let replacedDecisionID: DecisionID
    let successorStatement: String
    let replacedStatement: String
    let occurredAt: Date
    let citations: [AskCitation]
    let primaryCitation: AskCitation
}

enum AskTopicDecisionRelationshipPage {
    static func prepare(
        _ page: MeetingMemoryGraphFactPage,
        maximumCount: Int
    ) -> ([AskMemoryDecisionConflict], AskMemoryDisclosure)? {
        guard page.facts.count <= maximumCount,
              let synthesis = AskGraphFactSynthesisPage(page: page)
        else { return nil }
        let changes = synthesis.facts.compactMap(prepareChange)
        guard changes.count == synthesis.facts.count else { return nil }
        return (
            changes,
            AskMemoryDisclosure(
                hasMore: synthesis.hasMore,
                omittedStaleCount: synthesis.omittedStaleCount,
                omittedUnavailableCount: synthesis.omittedUnavailableCount))
    }

    private static func prepareChange(
        _ evidence: AskGraphFactSynthesisEvidence
    ) -> AskMemoryDecisionConflict? {
        let fact = evidence.fact
        guard case .decisionRelationship(let eventID) = fact.id,
              fact.kind == .decisionSupersededDecision,
              case .decision(let successorID) = fact.subject,
              case .decision(let replacedID) = fact.object,
              successorID != replacedID,
              fact.status == .confirmed,
              !fact.subjectText.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty,
              !fact.objectText.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty,
              evidence.sourceSegments.count >= 2,
              let primary = evidence.sourceSegments.first(where: {
                  $0.segmentID == fact.primaryEvidenceSegmentID
              })
        else { return nil }
        return AskMemoryDecisionConflict(
            id: eventID,
            successorDecisionID: successorID,
            replacedDecisionID: replacedID,
            successorStatement: fact.subjectText,
            replacedStatement: fact.objectText,
            occurredAt: fact.occurredAt,
            citations: evidence.sourceSegments,
            primaryCitation: primary)
    }
}
