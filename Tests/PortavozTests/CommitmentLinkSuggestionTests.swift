import Foundation
import PortavozCore
import XCTest

final class CommitmentLinkSuggestionTests: XCTestCase {
    private let sourceMeetingID = MeetingID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!)
    private let actionItemID = UUID(
        uuidString: "20000000-0000-0000-0000-000000000000")!
    private let personID = PersonID(
        rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000000")!)
    private let date = Date(timeIntervalSince1970: 1_785_600_000)

    func testRanksOnlyExactPersonAndSemanticEvidenceMatches() {
        let firstHit = segmentID(1)
        let secondHit = segmentID(2)
        let laterHit = segmentID(3)
        let best = target(
            id: 2,
            assignee: .person(personID),
            evidence: [secondHit, laterHit])
        let later = target(
            id: 1,
            assignee: .person(personID),
            evidence: [laterHit])
        let wrongPerson = target(
            id: 3,
            assignee: .person(PersonID()),
            evidence: [firstHit])
        let sameMeeting = target(
            id: 4,
            assignee: .person(personID),
            meetings: [sourceMeetingID],
            evidence: [firstHit])
        let closed = target(
            id: 5,
            status: .done,
            assignee: .person(personID),
            evidence: [firstHit])

        let suggestions = CommitmentLinkSuggestionPolicy.suggestions(
            sourceMeetingID: sourceMeetingID,
            actionItemID: actionItemID,
            candidateAssignee: .person(personID),
            semanticHitSegmentIDs: [firstHit, secondHit, laterHit],
            targets: [later, wrongPerson, sameMeeting, closed, best])

        XCTAssertEqual(suggestions.map(\.commitment.id), [best.commitment.id, later.commitment.id])
        XCTAssertEqual(suggestions.first?.bestSemanticRank, 2)
        XCTAssertEqual(suggestions.first?.matchedEvidenceSegmentIDs, [secondHit, laterHit])
        XCTAssertTrue(suggestions.allSatisfy { $0.sourceMeetingID == sourceMeetingID })
        XCTAssertTrue(suggestions.allSatisfy { $0.actionItemID == actionItemID })
    }

    func testRequiresExactKnownAssigneeOnBothSides() {
        let hit = segmentID(1)
        let mine = target(id: 1, assignee: .me, evidence: [hit])
        let unassigned = target(id: 2, assignee: .unassigned, evidence: [hit])

        XCTAssertEqual(
            CommitmentLinkSuggestionPolicy.suggestions(
                sourceMeetingID: sourceMeetingID,
                actionItemID: actionItemID,
                candidateAssignee: .me,
                semanticHitSegmentIDs: [hit],
                targets: [mine, unassigned])
                .map(\.commitment.id),
            [mine.commitment.id])
        XCTAssertTrue(CommitmentLinkSuggestionPolicy.suggestions(
            sourceMeetingID: sourceMeetingID,
            actionItemID: actionItemID,
            candidateAssignee: nil,
            semanticHitSegmentIDs: [hit],
            targets: [mine]).isEmpty)
        XCTAssertTrue(CommitmentLinkSuggestionPolicy.suggestions(
            sourceMeetingID: sourceMeetingID,
            actionItemID: actionItemID,
            candidateAssignee: .unassigned,
            semanticHitSegmentIDs: [hit],
            targets: [unassigned]).isEmpty)
    }

    func testMalformedOrUnboundedEvidenceFailsClosed() {
        let hit = segmentID(1)
        let candidate = target(
            id: 1,
            assignee: .person(personID),
            evidence: [hit])

        XCTAssertTrue(suggestions(hits: [hit, hit], targets: [candidate]).isEmpty)
        XCTAssertTrue(suggestions(
            hits: (0...CommitmentLinkSuggestionPolicy.maximumSemanticHitCount)
                .map(segmentID),
            targets: [candidate]).isEmpty)
        XCTAssertTrue(suggestions(hits: [hit], targets: [candidate], limit: 0).isEmpty)
        XCTAssertTrue(suggestions(
            hits: [hit],
            targets: Array(
                repeating: candidate,
                count: CommitmentLinkSuggestionPolicy.maximumTargetCount + 1))
            .isEmpty)
        XCTAssertTrue(suggestions(hits: [hit], targets: [candidate, candidate]).isEmpty)
    }

    func testMalformedTargetIsSkippedWithoutSuppressingValidSuggestions() {
        let hit = segmentID(1)
        let valid = target(id: 1, assignee: .person(personID), evidence: [hit])
        let blankTitle = target(
            id: 2,
            title: "  \n",
            assignee: .person(personID),
            evidence: [hit])
        let invalidDueDate = target(
            id: 3,
            assignee: .person(personID),
            dueAt: Date(timeIntervalSinceReferenceDate: .nan),
            evidence: [hit])
        let duplicateEvidence = target(
            id: 4,
            assignee: .person(personID),
            evidence: [hit, hit])
        let tooMuchEvidence = target(
            id: 5,
            assignee: .person(personID),
            evidence: (0...CommitmentLinkSuggestionPolicy.maximumRelatedRowCount)
                .map(segmentID))

        XCTAssertEqual(
            suggestions(
                hits: [hit],
                targets: [blankTitle, invalidDueDate, duplicateEvidence, tooMuchEvidence, valid])
                .map(\.commitment.id),
            [valid.commitment.id])
    }

    func testOrderingIsBoundedAndStableAfterSemanticTies() {
        let hit = segmentID(1)
        let targets = (1...5).reversed().map {
            target(id: $0, assignee: .person(personID), evidence: [hit])
        }

        let suggestions = suggestions(hits: [hit], targets: targets, limit: 3)

        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(
            suggestions.map(\.commitment.id.rawValue.uuidString),
            suggestions.map(\.commitment.id.rawValue.uuidString).sorted())
    }

    private func suggestions(
        hits: [UUID],
        targets: [CommitmentLinkSuggestionTarget],
        limit: Int = CommitmentLinkSuggestionPolicy.maximumSuggestionCount
    ) -> [CommitmentLinkSuggestion] {
        CommitmentLinkSuggestionPolicy.suggestions(
            sourceMeetingID: sourceMeetingID,
            actionItemID: actionItemID,
            candidateAssignee: .person(personID),
            semanticHitSegmentIDs: hits,
            targets: targets,
            limit: limit)
    }

    private func target(
        id: Int,
        title: String = "Prepare the rollout",
        status: CommitmentStatus = .confirmed,
        assignee: CommitmentAssignee,
        dueAt: Date? = nil,
        meetings: [MeetingID] = [],
        evidence: [UUID]
    ) -> CommitmentLinkSuggestionTarget {
        CommitmentLinkSuggestionTarget(
            commitment: Commitment(
                id: CommitmentID(rawValue: stableUUID(id)),
                title: title,
                status: status,
                assignee: assignee,
                dueAt: dueAt,
                createdAt: date),
            sourceMeetingIDs: meetings,
            evidenceSegmentIDs: evidence)
    }

    private func segmentID(_ value: Int) -> UUID { stableUUID(value + 100) }

    private func stableUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
