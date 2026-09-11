import PortavozCore
import XCTest

final class CompanionCardAdmissionTests: XCTestCase {
    func testGrowingQuestionLineageReplacesTheShorterCard() {
        let sourceID = UUID()
        let short = card(
            question: "Do we use the device ID?",
            askedAt: 10,
            sourceIDs: [sourceID])
        let complete = card(
            question: "Do we use the device ID and filter by closeness and time?",
            askedAt: 10,
            sourceIDs: [sourceID])

        XCTAssertEqual(
            CompanionCardAdmission.decision(
                existing: [short],
                candidate: complete),
            .replace(index: 0))
        XCTAssertEqual(
            CompanionCardAdmission.decision(
                existing: [complete],
                candidate: short),
            .reject)
    }

    func testAdjacentNearDuplicateQuestionIsRejectedWithoutSharedLineage() {
        let first = card(
            question: "Do we scan three or four packets for every device and compare closeness?",
            askedAt: 20,
            sourceIDs: [UUID()])
        let repeated = card(
            question: "Do we scan three or four packets for every device and compare closeness in time?",
            askedAt: 25,
            sourceIDs: [UUID()])

        XCTAssertEqual(
            CompanionCardAdmission.decision(
                existing: [first],
                candidate: repeated),
            .replace(index: 0))
    }

    func testNegatedQuestionDoesNotCollapseIntoOppositeMeaning() {
        let positive = card(
            question: "Should we ship the API change to production this Friday?",
            askedAt: 30,
            sourceIDs: [UUID()])
        let negative = card(
            question: "Should we not ship the API change to production this Friday?",
            askedAt: 31,
            sourceIDs: [UUID()])

        XCTAssertEqual(
            CompanionCardAdmission.decision(
                existing: [positive],
                candidate: negative),
            .append)
    }

    func testSimilarQuestionOutsideLiveWindowRemainsIndependent() {
        let first = card(
            question: "What did we decide about the API migration and rollout schedule?",
            askedAt: 30,
            sourceIDs: [UUID()])
        let later = card(
            question: "What did we decide about the API migration and rollout schedule?",
            askedAt: 90,
            sourceIDs: [UUID()])

        XCTAssertEqual(
            CompanionCardAdmission.decision(
                existing: [first],
                candidate: later),
            .append)
    }

    private func card(
        question: String,
        askedAt: TimeInterval,
        sourceIDs: [UUID]
    ) -> CompanionCard {
        let id = UUID()
        return CompanionCard(
            id: id,
            question: question,
            answer: "Answer",
            kind: .context,
            source: "on-device",
            askedAt: askedAt,
            evidence: CompanionCardEvidence(
                cardID: id,
                sourceTranscriptRevision: 0,
                questionSegmentIDs: sourceIDs))
    }
}
