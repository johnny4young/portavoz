import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskGraphFactSelectionTests: XCTestCase {
    func testProductionSelectionReservesTranscriptRankBeforeGraphFacts() throws {
        let fixture = SelectionFixture()
        let citations = (0..<8).map(fixture.citation)
        let facts = (0..<6).map { fixture.fact(index: $0) }

        let selected = try fixture.input(
            citations: citations,
            facts: facts).selecting()

        XCTAssertEqual(
            selected.transcriptCitations.compactMap { $0.segmentID },
            citations.prefix(6).compactMap { $0.segmentID })
        guard case .facts(let page) = selected.graphFacts else {
            return XCTFail("bounded facts must remain available")
        }
        XCTAssertEqual(
            page.facts.map { $0.fact.objectText },
            facts.prefix(4).map { $0.objectText })
        XCTAssertEqual(page.selectionOmittedCount, 2)
        XCTAssertFalse(page.isComplete)
        XCTAssertEqual(selected.selection, AskFactAwareSelectionDisclosure(
            transcriptCandidateCount: 8,
            selectedTranscriptCount: 6,
            graphFactCandidateCount: 6,
            selectedGraphFactCount: 4,
            additionalGraphSourceCount: 4,
            omittedGraphFactCount: 2))
        XCTAssertTrue(selected.isFactAwareGenerationReady)
        XCTAssertEqual(selected.selecting(), selected)
    }

    func testGraphFactsNeverOutnumberSelectedTranscriptEvidence() throws {
        let fixture = SelectionFixture()
        let selected = try fixture.input(
            citations: (0..<2).map(fixture.citation),
            facts: (0..<5).map { fixture.fact(index: $0) }).selecting()

        guard case .facts(let page) = selected.graphFacts else {
            return XCTFail("facts within the transcript bound must be selected")
        }
        XCTAssertEqual(page.facts.count, 2)
        XCTAssertEqual(page.selectionOmittedCount, 3)
        XCTAssertEqual(selected.selection?.selectedTranscriptCount, 2)
        XCTAssertEqual(selected.selection?.selectedGraphFactCount, 2)
    }

    func testTranscriptOverlapConsumesNoAdditionalGraphSourceBudget() throws {
        let fixture = SelectionFixture()
        let evidence = fixture.evidence(index: 20)
        let citation = fixture.citation(from: evidence)
        let input = try fixture.input(
            citations: [citation],
            facts: [fixture.fact(index: 0, evidence: [evidence])])
        let policy = try XCTUnwrap(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 1,
            maximumGraphFacts: 1,
            maximumAdditionalGraphSources: 0))

        let selected = input.selecting(using: policy)

        XCTAssertEqual(selected.selection?.additionalGraphSourceCount, 0)
        XCTAssertTrue(selected.isFactAwareGenerationReady)
    }

    func testAdditionalSourceBudgetPreservesFactAtomicityAndPrefixOrder() throws {
        let fixture = SelectionFixture()
        let first = fixture.fact(
            index: 0,
            evidence: [
                fixture.evidence(index: 20),
                fixture.evidence(index: 21),
            ])
        let second = fixture.fact(
            index: 1,
            evidence: [
                fixture.evidence(index: 22),
                fixture.evidence(index: 23),
            ])
        let smallerLaterFact = fixture.fact(
            index: 2,
            evidence: [fixture.evidence(index: 24)])
        let policy = try XCTUnwrap(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 4,
            maximumGraphFacts: 4,
            maximumAdditionalGraphSources: 3))

        let selected = try fixture.input(
            citations: (0..<4).map(fixture.citation),
            facts: [first, second, smallerLaterFact])
            .selecting(using: policy)

        guard case .facts(let page) = selected.graphFacts else {
            return XCTFail("the first atomic fact fits the budget")
        }
        XCTAssertEqual(page.facts.map(\.fact.objectText), [first.objectText])
        XCTAssertEqual(page.selectionOmittedCount, 2)
        XCTAssertEqual(selected.selection?.additionalGraphSourceCount, 2)
        XCTAssertTrue(selected.isFactAwareGenerationReady)
    }

    func testNoAtomicFactFitReturnsTypedBudgetExhaustion() throws {
        let fixture = SelectionFixture()
        let policy = try XCTUnwrap(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 1,
            maximumGraphFacts: 1,
            maximumAdditionalGraphSources: 0))

        let selected = try fixture.input(
            citations: [fixture.citation(index: 0)],
            facts: [fixture.fact(index: 0)])
            .selecting(using: policy)

        guard case .selectionBudgetExceeded(let disclosure) =
            selected.graphFacts
        else {
            return XCTFail("a non-fitting exact fact must abstain explicitly")
        }
        XCTAssertEqual(disclosure.selectedGraphFactCount, 0)
        XCTAssertEqual(disclosure.omittedGraphFactCount, 1)
        XCTAssertFalse(selected.isFactAwareGenerationReady)
    }

    func testSelectionDisclosureMustMatchTheSelectedMaterial() throws {
        let fixture = SelectionFixture()
        let evidence = fixture.evidence(index: 20)
        let selected = try fixture.input(
            citations: [fixture.citation(from: evidence)],
            facts: [fixture.fact(index: 0, evidence: [evidence])])
            .selecting()
        guard case .facts(let page) = selected.graphFacts else {
            return XCTFail("fixture must produce selected facts")
        }
        let forged = try XCTUnwrap(AskFactAwareSelectionDisclosure(
            transcriptCandidateCount: 2,
            selectedTranscriptCount: 2,
            graphFactCandidateCount: 1,
            selectedGraphFactCount: 1,
            additionalGraphSourceCount: 0,
            omittedGraphFactCount: 0))

        XCTAssertFalse(AskSynthesisInput(
            transcriptCitations: selected.transcriptCitations,
            graphFacts: .facts(page),
            selection: forged).isFactAwareGenerationReady)
    }

    func testInvalidSelectionPoliciesFailClosed() {
        XCTAssertNil(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 0,
            maximumGraphFacts: 1,
            maximumAdditionalGraphSources: 1))
        XCTAssertNil(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 1,
            maximumGraphFacts: 0,
            maximumAdditionalGraphSources: 1))
        XCTAssertNil(AskFactAwareSelectionPolicy(
            maximumTranscriptCitations: 1,
            maximumGraphFacts: 1,
            maximumAdditionalGraphSources: -1))
    }
}

private struct SelectionFixture {
    let meetingID = MeetingID()

    func citation(index: Int) -> AskCitation {
        AskCitation(
            segmentID: segmentID(index),
            meetingID: meetingID,
            meetingTitle: "Planning",
            timestamp: TimeInterval(index + 1),
            transcriptRevision: 3,
            text: "Transcript \(index)")
    }

    func citation(from evidence: MeetingMemoryGraphEvidence) -> AskCitation {
        AskCitation(
            segmentID: evidence.segmentID,
            meetingID: evidence.meetingID,
            meetingTitle: evidence.meetingTitle,
            timestamp: evidence.startTime,
            transcriptRevision: evidence.transcriptRevision,
            text: evidence.text)
    }

    func evidence(index: Int) -> MeetingMemoryGraphEvidence {
        MeetingMemoryGraphEvidence(
            meetingID: meetingID,
            meetingTitle: "Planning",
            meetingStartedAt: Date(timeIntervalSince1970: 900),
            transcriptRevision: 3,
            segmentID: segmentID(index),
            startTime: TimeInterval(index + 1),
            endTime: TimeInterval(index + 2),
            text: "Evidence \(index)",
            language: "en")
    }

    func fact(
        index: Int,
        evidence: [MeetingMemoryGraphEvidence]? = nil
    ) -> MeetingMemoryGraphFact {
        let commitmentID = CommitmentID()
        let evidence = evidence ?? [self.evidence(index: index + 20)]
        return MeetingMemoryGraphFact(
            id: .commitment(commitmentID),
            kind: .personCommittedTo,
            subject: .person(PersonID()),
            object: .commitment(commitmentID),
            subjectText: "Owner \(index)",
            objectText: "Fact \(index)",
            status: .active,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
            evidence: evidence,
            primaryEvidenceSegmentID: evidence[0].segmentID)
    }

    func input(
        citations: [AskCitation],
        facts: [MeetingMemoryGraphFact]
    ) throws -> AskSynthesisInput {
        let page = try XCTUnwrap(AskGraphFactSynthesisPage(page:
            MeetingMemoryGraphFactPage(
                facts: facts,
                hasMore: false,
                projectionGeneration: 7,
                omittedStaleCount: 0,
                omittedUnavailableCount: 0)))
        return AskSynthesisInput(
            transcriptCitations: citations,
            graphFacts: .facts(page))
    }

    private func segmentID(_ index: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012d",
            index + 1))!
    }
}
