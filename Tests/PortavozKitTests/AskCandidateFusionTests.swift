import Foundation
import XCTest
@testable import ApplicationKit
@testable import IntelligenceKit
@testable import StorageKit

final class AskCandidateFusionTests: XCTestCase {
    func testLiteralLexicalLeadSurvivesWeakConsensusWithoutDroppingSemanticOnlyHits() {
        let lexical = [hit(1, "Inez owns NET-42."), hit(2, "Max owns NET-420.")]
        let semantic = [id(2), id(3)]
        let original = RAGFusion.fuse(lexical: lexical.map(\.segmentID), semantic: semantic, limit: 10)
        XCTAssertEqual(original.first, id(2), "characterize the actual weak-consensus failure")
        let actual = fuse(question: "Who owns NET-42?",
                                             lexical: lexical, semantic: semantic, limit: 10)
        XCTAssertEqual(actual, [id(1)] + original.filter { $0 != id(1) })
        XCTAssertTrue(actual.contains(id(3)), "semantic-only or spoken evidence is not hard-filtered")
    }

    func testNaturalSpokenMultipleNegatedOrMismatchedQuestionsKeepOrdinaryFusion() {
        let lexical = [hit(1, "Inez owns NET-42."), hit(2, "Current assignment details.")]
        for question in [
            "Who owns the network incident?", "Who owns net forty two?",
            "Compare NET-42 and NET-43.", "Who owns NET-420?",
            "Who owns NET-42, not the other ticket?", "Who doesn't own NET-42?",
            "Who doesn’t own NET-42?", "¿Quién no revisa NET-42?",
            "¿Quién revisa NET-42 sin incluir la propuesta?", "NET-42 except the draft",
            "NET-42 excluding the draft", "NET-42 excepto el borrador"
        ] {
            assertOrdinary(question: question, lexical: lexical)
        }
    }

    func testAmbiguousSpokenOrDifferentLexicalLeadIsNotPromoted() {
        for passage in [
            "Inez owns NET-42 and NET-43.", "Inez owns NET-420.",
            "Inez owns net forty two.", "Inez owns the network incident.",
            "Do not mistake prefixNET-42suffix for the standalone reference."
        ] {
            assertOrdinary(question: "Who owns NET-42?", lexical: [hit(1, passage), hit(2, "Other evidence")])
        }
    }

    func testReferenceIdentityIsCaseInsensitiveAndRepeatedReferenceIsNotAmbiguity() {
        let lexical = [hit(1, "NET-42 belongs to Inez. Net-42 is confirmed."), hit(2, "Other evidence")]
        let result = fuse(question: "Who owns net-42 (NET-42)?",
                                              lexical: lexical, semantic: [id(2)], limit: 10)
        XCTAssertEqual(result.first, id(1))
    }

    func testReferenceTokensDoNotInferPrefixesDatesVersionsOrUnicodeLookalikes() {
        for text in ["NET-42_extra", "x_NET-42", "NET-42suffix", "NET-42-43", "2026-09",
                     "26.1", "NET–42", "NÉT-42", "NET-４２", "NET-42é", "NET-12345678901234567"] {
            XCTAssertNil(AskCandidateFusion.soleReference(in: text, maximumBytes: 1_000), text)
        }
        XCTAssertEqual(AskCandidateFusion.soleReference(in: "(NET-42), done.", maximumBytes: 100), "net-42")
        XCTAssertNil(AskCandidateFusion.soleReference(in: "NET-42 and NET-43", maximumBytes: 100))
    }

    func testOversizedQuestionOrPassageKeepsOrdinaryFusion() {
        assertOrdinary(question: "NET-42 " + String(repeating: "a", count: 16_000),
                       lexical: [hit(1, "NET-42 belongs to Inez."), hit(2, "Other")])
        assertOrdinary(question: "NET-42", lexical: [
            hit(1, "NET-42 " + String(repeating: "a", count: 128_000)), hit(2, "Other")
        ])
    }

    func testLimitsEmptyChannelsAndAlreadyLeadingCandidateRemainBounded() {
        let lexical = [hit(1, "NET-42 belongs to Inez."), hit(2, "Other")]
        for limit in [-1, 0] {
            XCTAssertTrue(fuse(question: "NET-42", lexical: lexical,
                                                   semantic: [id(2)], limit: limit).isEmpty)
        }
        XCTAssertEqual(fuse(question: "NET-42", lexical: lexical,
                                                 semantic: [id(2)], limit: 1), [id(1)])
        XCTAssertEqual(fuse(question: "NET-42", lexical: lexical,
                                                 semantic: [], limit: 10), [id(1), id(2)])
        XCTAssertEqual(fuse(question: "NET-42", lexical: [],
                                                 semantic: [id(3)], limit: 10), [id(3)])
        XCTAssertEqual(fuse(question: "NET-42", lexical: lexical,
                                                 semantic: [id(1), id(2)], limit: 10), [id(1), id(2)])
    }

    func testChangedOrMissingMaterializedEvidenceNeverBorrowsOldLexicalReference() {
        let lead = hit(1, "NET-42 belongs to Inez.")
        let lexical = [lead, hit(2, "Other evidence")]
        let expected = RAGFusion.fuse(lexical: lexical.map(\.segmentID), semantic: [id(2)], limit: 10)
        var alternatives: [SearchHit?] = (0..<6).map { field in
            SearchHit(meetingID: .init(rawValue: id(field == 0 ? 200 : 100)),
                      meetingTitle: lead.meetingTitle, resultID: field == 1 ? id(9) : lead.resultID,
                      sourceSegmentIDs: field == 2 ? [id(9)] : lead.sourceSegmentIDs,
                      text: field == 3 ? "NET-42 belongs to Max." : lead.text, snippet: lead.snippet,
                      startTime: field == 4 ? 30 : lead.startTime,
                      transcriptRevision: field == 5 ? 2 : lead.transcriptRevision)
        }
        alternatives.append(nil)
        for resolved in alternatives {
            XCTAssertEqual(AskCandidateFusion.fuse(question: "Who owns NET-42?", lexical: lexical,
                            semantic: [id(2)], resolvedLead: resolved, limit: 10), expected)
        }
    }

    func testPresentationMetadataDoesNotInvalidateIdenticalEvidence() {
        let lead = hit(1, "NET-42 belongs to Inez.")
        let resolved = SearchHit(meetingID: lead.meetingID, meetingTitle: "Renamed meeting",
            resultID: lead.resultID, sourceSegmentIDs: lead.sourceSegmentIDs, text: lead.text,
            snippet: "[NET-42]", startTime: lead.startTime,
            transcriptRevision: lead.transcriptRevision, semanticSimilarity: 0.7)
        XCTAssertEqual(AskCandidateFusion.fuse(question: "NET-42", lexical: [lead, hit(2, "Other")],
                        semantic: [id(2)], resolvedLead: resolved, limit: 10).first, lead.resultID)
    }

    private func assertOrdinary(question: String, lexical: [SearchHit],
                                file: StaticString = #filePath, line: UInt = #line) {
        let semantic = [id(2), id(3)]
        XCTAssertEqual(fuse(question: question, lexical: lexical, semantic: semantic, limit: 10),
                       RAGFusion.fuse(lexical: lexical.map(\.segmentID), semantic: semantic, limit: 10),
                       file: file, line: line)
    }

    private func fuse(question: String, lexical: [SearchHit], semantic: [UUID], limit: Int) -> [UUID] {
        AskCandidateFusion.fuse(question: question, lexical: lexical, semantic: semantic,
                                resolvedLead: lexical.first, limit: limit)
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func hit(_ number: Int, _ text: String) -> SearchHit {
        SearchHit(meetingID: .init(rawValue: id(100)), meetingTitle: "Synthetic operations",
                  segmentID: id(number), text: text, snippet: text, startTime: Double(number),
                  transcriptRevision: 1)
    }
}
