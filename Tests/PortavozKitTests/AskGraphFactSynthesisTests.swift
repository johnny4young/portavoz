import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class AskGraphFactSynthesisTests: XCTestCase {
    func testValidPagePreservesFactsExactSourcesAndDisclosure() throws {
        let fixture = SynthesisFixture()
        let fact = fixture.fact()
        let page = fixture.page(
            facts: [fact],
            hasMore: true,
            omittedStaleCount: 2,
            omittedUnavailableCount: 3)

        let input = AskEvidenceBundle(
            transcriptCitations: [fixture.citation()],
            graphFacts: .result(.facts(page))).synthesisInput.selecting()

        XCTAssertTrue(input.isFactAwareGenerationReady)
        XCTAssertEqual(input.selection?.selectedTranscriptCount, 1)
        XCTAssertEqual(input.selection?.selectedGraphFactCount, 1)
        guard case .facts(let prepared) = input.graphFacts else {
            return XCTFail("valid graph material must remain typed")
        }
        XCTAssertEqual(prepared.facts.map(\.fact), [fact])
        XCTAssertEqual(prepared.facts[0].sourceSegments, [fixture.citation()])
        XCTAssertTrue(prepared.hasMore)
        XCTAssertEqual(prepared.projectionGeneration, 7)
        XCTAssertEqual(prepared.omittedStaleCount, 2)
        XCTAssertEqual(prepared.omittedUnavailableCount, 3)
        XCTAssertFalse(prepared.isComplete)
    }

    func testMalformedFactOrSourceFailsClosed() {
        let fixture = SynthesisFixture()
        let invalidFacts = [
            fixture.fact(subjectText: "  "),
            fixture.fact(objectText: "\n"),
            fixture.fact(occurredAt: Date(timeIntervalSince1970: .infinity)),
            fixture.fact(primarySegmentID: UUID()),
            fixture.fact(evidence: [fixture.evidence(transcriptRevision: -1)]),
            fixture.fact(evidence: [fixture.evidence(startTime: -.infinity)]),
            fixture.fact(evidence: [fixture.evidence(startTime: -1)]),
            fixture.fact(evidence: [fixture.evidence(startTime: 4, endTime: 3)]),
            fixture.fact(evidence: [fixture.evidence(meetingTitle: " ")]),
            fixture.fact(evidence: [fixture.evidence(text: "")]),
            fixture.fact(evidence: [fixture.evidence(language: " ")]),
        ]

        for fact in invalidFacts {
            XCTAssertNil(
                AskGraphFactSynthesisEvidence(fact: fact),
                "malformed exact evidence must not reach generation")
        }
    }

    func testPageRejectsDuplicateFactsAndInconsistentSharedSources() {
        let fixture = SynthesisFixture()
        let duplicateID = fixture.fact()
        XCTAssertNil(AskGraphFactSynthesisPage(page: fixture.page(
            facts: [duplicateID, duplicateID])))

        let sharedID = fixture.segmentID
        let first = fixture.fact(
            id: .commitment(CommitmentID()),
            evidence: [fixture.evidence(segmentID: sharedID)])
        let second = fixture.fact(
            id: .commitment(CommitmentID()),
            evidence: [fixture.evidence(
                segmentID: sharedID,
                text: "Different current text")])
        XCTAssertNil(AskGraphFactSynthesisPage(page: fixture.page(
            facts: [first, second])))
    }

    func testFactAwareReadinessRequiresExactTranscriptLane() throws {
        let fixture = SynthesisFixture()
        let page = try XCTUnwrap(AskGraphFactSynthesisPage(
            page: fixture.page(facts: [fixture.fact()])))

        XCTAssertFalse(AskSynthesisInput(
            transcriptCitations: [],
            graphFacts: .facts(page)).selecting().isFactAwareGenerationReady)
        XCTAssertFalse(AskSynthesisInput(
            transcriptCitations: [fixture.citation(includeSegmentID: false)],
            graphFacts: .facts(page)).selecting().isFactAwareGenerationReady)
        XCTAssertFalse(AskSynthesisInput(
            transcriptCitations: [fixture.citation(timestamp: .nan)],
            graphFacts: .facts(page)).selecting().isFactAwareGenerationReady)
        XCTAssertFalse(AskSynthesisInput(
            transcriptCitations: [fixture.citation(transcriptRevision: -1)],
            graphFacts: .facts(page)).selecting().isFactAwareGenerationReady)
        XCTAssertTrue(AskSynthesisInput(
            transcriptCitations: [fixture.citation()],
            graphFacts: .facts(page)).selecting().isFactAwareGenerationReady)
    }

    func testOverlappingTranscriptAndFactSourceMustBeIdentical() throws {
        let fixture = SynthesisFixture()
        let page = try XCTUnwrap(AskGraphFactSynthesisPage(
            page: fixture.page(facts: [fixture.fact()])))
        let inconsistent = fixture.citation(text: "Stale text")

        let input = AskSynthesisInput(
            transcriptCitations: [inconsistent],
            graphFacts: .facts(page)).selecting()

        XCTAssertFalse(input.isFactAwareGenerationReady)
    }
}

private struct SynthesisFixture {
    let meetingID = MeetingID()
    let segmentID = UUID()

    func citation(
        includeSegmentID: Bool = true,
        timestamp: TimeInterval = 3,
        transcriptRevision: Int = 0,
        text: String = "Mara committed to ship on Friday."
    ) -> AskCitation {
        AskCitation(
            segmentID: includeSegmentID ? segmentID : nil,
            meetingID: meetingID,
            meetingTitle: "Planning",
            timestamp: timestamp,
            transcriptRevision: transcriptRevision,
            text: text)
    }

    func evidence(
        segmentID: UUID? = nil,
        meetingTitle: String = "Planning",
        transcriptRevision: Int = 0,
        startTime: TimeInterval = 3,
        endTime: TimeInterval = 5,
        text: String = "Mara committed to ship on Friday.",
        language: String? = "en"
    ) -> MeetingMemoryGraphEvidence {
        MeetingMemoryGraphEvidence(
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingStartedAt: Date(timeIntervalSince1970: 997),
            transcriptRevision: transcriptRevision,
            segmentID: segmentID ?? self.segmentID,
            startTime: startTime,
            endTime: endTime,
            text: text,
            language: language)
    }

    func fact(
        id: MeetingMemoryGraphFactID? = nil,
        subjectText: String = "Mara",
        objectText: String = "Ship rollout",
        occurredAt: Date = Date(timeIntervalSince1970: 1_000),
        evidence: [MeetingMemoryGraphEvidence]? = nil,
        primarySegmentID: UUID? = nil
    ) -> MeetingMemoryGraphFact {
        let commitmentID = CommitmentID()
        return MeetingMemoryGraphFact(
            id: id ?? .commitment(commitmentID),
            kind: .personCommittedTo,
            subject: .person(PersonID()),
            object: .commitment(commitmentID),
            subjectText: subjectText,
            objectText: objectText,
            status: .active,
            occurredAt: occurredAt,
            evidence: evidence ?? [self.evidence()],
            primaryEvidenceSegmentID: primarySegmentID ?? segmentID)
    }

    func page(
        facts: [MeetingMemoryGraphFact],
        hasMore: Bool = false,
        projectionGeneration: Int = 7,
        omittedStaleCount: Int = 0,
        omittedUnavailableCount: Int = 0
    ) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: facts,
            hasMore: hasMore,
            projectionGeneration: projectionGeneration,
            omittedStaleCount: omittedStaleCount,
            omittedUnavailableCount: omittedUnavailableCount)
    }
}
