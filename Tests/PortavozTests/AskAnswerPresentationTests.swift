import ApplicationKit
import Foundation
import PortavozCore
@testable import portavoz_app
import XCTest

final class AskAnswerPresentationTests: XCTestCase {
    func testGenerationFailuresStayDistinctWhileKeepingExactEvidence() {
        let citation = AskCitation(
            segmentID: UUID(),
            meetingID: MeetingID(),
            meetingTitle: "Planning",
            timestamp: 3,
            text: "The rollout remains Friday.")
        let expectations: [(AskGenerationOutcome, String)] = [
            (.unavailable, "unavailable"),
            (.failed, "could not finish"),
            (.timedOut, "took too long"),
        ]

        for (outcome, fragment) in expectations {
            let result = AskMeetingAnswer(
                question: "When?",
                generatedText: nil,
                citations: [citation],
                generationOutcome: outcome)
            XCTAssertEqual(
                AskAnswerPresentation.text(for: result),
                L10n.text("Closest passages from your meetings:"))
            XCTAssertTrue(
                AskAnswerPresentation.statusText(
                    for: outcome,
                    hasCitations: true)?.contains(fragment) == true,
                outcome.rawValue)
        }
    }

    func testGeneratedAndNoEvidenceAnswersDoNotShowEngineWarning() {
        XCTAssertNil(AskAnswerPresentation.statusText(
            for: .generated,
            hasCitations: true))
        XCTAssertNil(AskAnswerPresentation.statusText(
            for: .failed,
            hasCitations: false))
    }
}
