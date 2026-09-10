import Foundation
import IntelligenceKit
import XCTest

/// GAPS #13: a real standup stated its priority out loud, the transcript kept
/// every word, and nothing in the product had a place to put it. The detector
/// is deliberately narrow — an explicit copular statement naming a bounded
/// subject, or nothing at all. Over that meeting's 305 finalized segments it
/// fired once, on the one line that declared a priority.
///
/// The fixtures below reproduce the shapes seen in the field with neutral
/// subjects; the field transcript itself stays out of this repository.
final class StatedPriorityDetectorTests: XCTestCase {
    private let row = UUID(uuidString: "9B100000-0000-4000-8000-000000000001")!

    func testTheFieldShapeThatMotivatedThisDetector() throws {
        let caption = "Priority is the billing migration, whatever is in "
            + "progress, any review"
        let priority = try XCTUnwrap(detect(caption))

        XCTAssertEqual(priority.subject, "the billing migration")
        XCTAssertEqual(
            priority.statement, caption,
            "the exact caption is the evidence and must survive verbatim")
        XCTAssertEqual(priority.sourceRowID, row)
        XCTAssertEqual(priority.statedAt, 107, accuracy: 0.001)
    }

    func testAnAnchorMayCarryATimeQualifier() {
        XCTAssertEqual(
            detect("The priority right now is the payments migration.")?.subject,
            "the payments migration")
    }

    func testTheSubjectMayComeBeforeTheAnchor() {
        XCTAssertEqual(
            detect("Shipping the release notes is our top priority.")?.subject,
            "Shipping the release notes")
    }

    func testSpanishReadsInBothDirections() {
        XCTAssertEqual(
            detect("La prioridad es el cierre contable.")?.subject,
            "el cierre contable")
        XCTAssertEqual(
            detect("Cerrar el reporte es la prioridad.")?.subject,
            "Cerrar el reporte")
    }

    func testAskingWhatThePriorityIsStatesNothing() {
        XCTAssertNil(detect("What is the priority for this week?"))
        XCTAssertNil(detect("¿Cuál es la prioridad de esta semana?"))
    }

    func testANegatedOrHypotheticalPriorityIsNotAStatedOne() {
        XCTAssertNil(detect("The priority is not the dashboard."))
        XCTAssertNil(detect("If the priority is the dashboard we move the team."))
        XCTAssertNil(detect("La prioridad no es el dashboard."))
    }

    func testPastTenseIsHistoryAndReprioritizesNothing() {
        XCTAssertNil(detect("The priority was the payments migration."))
    }

    func testEmphasisWithoutAnExplicitStatementIsIgnored() {
        XCTAssertNil(detect("We should really focus on the billing migration first."))
        XCTAssertNil(detect("Let's get the billing migration out first."))
        XCTAssertNil(
            detect("Everything else is on hold until those are finished."),
            "on-hold phrasing is real, but it is also ordinary emphasis")
    }

    func testASubjectThatNamesNothingIsRejected() {
        XCTAssertNil(detect("The priority is that."))
        XCTAssertNil(detect("The priority is it."))
    }

    func testAClauseThatNeverNamesASubjectIsRejectedRatherThanTruncated() {
        XCTAssertNil(
            detect("The priority is making sure every single team has finished "
                + "their quarterly compliance paperwork before the audit"),
            "a truncated subject would read as a priority nobody stated")
    }

    func testRestatingTheSamePriorityResolvesToOneIdentity() throws {
        let first = try XCTUnwrap(detect("Priority is Billing Migration."))
        let second = try XCTUnwrap(detect("The priority is billing migration."))

        XCTAssertEqual(first.subjectKey, second.subjectKey)
        XCTAssertNotEqual(first.id, second.id, "each detection is its own offer")
    }

    func testATranscriptWithoutTheWordAbstainsImmediately() {
        XCTAssertNil(detect("We shipped the billing migration to staging this morning."))
    }

    private func detect(_ text: String) -> StatedPriority? {
        StatedPriorityDetector.detect(in: text, rowID: row, statedAt: 107)
    }
}
