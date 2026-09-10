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

    // MARK: - Demotion (the inversion this detector shipped with)

    func testAQualifierThatDemotesTheAnchorInvertsTheSpeaker() {
        XCTAssertNil(
            detect("The dashboard is a low priority."),
            "naming what does NOT take precedence must never become a priority")
        XCTAssertNil(detect("That migration is a lower priority than the release."))
        XCTAssertNil(detect("El dashboard es una prioridad baja."))
        XCTAssertNil(detect("Esa tarea es la ultima prioridad."))
        XCTAssertNil(
            detect("The priority is low."),
            "a bare qualifier names nothing to prioritize")
    }

    func testAPromotingQualifierStillReads() {
        XCTAssertEqual(
            detect("The dashboard is a high priority.")?.subject, "The dashboard")
        XCTAssertEqual(
            detect("Shipping the release notes is our top priority.")?.subject,
            "Shipping the release notes")
    }

    // MARK: - Wider vocabulary, same grammar

    func testOtherExplicitDeclarationsOfPrecedence() {
        XCTAssertEqual(
            detect("Lo mas importante es cerrar el reporte.")?.subject,
            "cerrar el reporte")
        XCTAssertEqual(
            detect("The most important thing is the billing migration.")?.subject,
            "the billing migration")
        XCTAssertEqual(
            detect("The focus is the checkout redesign.")?.subject,
            "the checkout redesign")
        XCTAssertEqual(
            detect("El foco es la migracion de datos.")?.subject,
            "la migracion de datos")
    }

    func testPrecedenceAssertedByAVerb() {
        XCTAssertEqual(
            detect("The security patch takes precedence.")?.subject,
            "The security patch")
        XCTAssertEqual(
            detect("The release notes come first.")?.subject, "The release notes")
        XCTAssertEqual(
            detect("El reporte va primero.")?.subject, "El reporte")
    }

    func testPrecedenceVerbsKeepTheirAbstentions() {
        XCTAssertNil(detect("If the security patch takes precedence we replan."))
        XCTAssertNil(detect("Which one comes first?"))
    }

    // MARK: - Sentences that span captions

    func testOneSentenceSplitAcrossCaptionsIsStillRead() throws {
        let captions = [
            caption("So the priority.", at: 10),
            caption("Yeah.", at: 12),
            caption("It is the billing migration.", at: 14)
        ]

        let priority = try XCTUnwrap(StatedPriorityDetector.detect(inRecent: captions))

        XCTAssertEqual(priority.subject, "the billing migration")
        XCTAssertEqual(
            priority.sourceRowID, captions[0].id,
            "the row carrying the declaration is the evidence anchor")
        XCTAssertEqual(priority.statedAt, 10, accuracy: 0.001)
        XCTAssertTrue(priority.statement.contains("So the priority"))
    }

    func testASentenceIsNeverAssembledOutOfTwoPeoplesWords() {
        let captions = [
            caption("So the priority.", at: 10, speaker: "S1"),
            caption("It is the billing migration.", at: 12, speaker: "S2")
        ]

        XCTAssertNil(StatedPriorityDetector.detect(inRecent: captions))
    }

    func testCaptionsTooFarApartAreNotJoined() {
        let gap = StatedPriorityDetector.maximumJoinSeconds + 5
        let captions = [
            caption("So the priority.", at: 10),
            caption("It is the billing migration.", at: 10 + gap)
        ]

        XCTAssertNil(StatedPriorityDetector.detect(inRecent: captions))
    }

    func testASingleCaptionStillWinsBeforeAnyJoining() throws {
        let captions = [
            caption("Nothing to see here.", at: 4),
            caption("Priority is the billing migration.", at: 6)
        ]

        let priority = try XCTUnwrap(StatedPriorityDetector.detect(inRecent: captions))

        XCTAssertEqual(priority.subject, "the billing migration")
        XCTAssertEqual(priority.sourceRowID, captions[1].id)
    }

    func testAccentsAreFoldedExceptWhereTheyChangeTheWord() {
        // Spanish recognizer output drops accents constantly.
        XCTAssertEqual(
            detect("La prioridad numero uno es el cierre contable.")?.subject,
            "el cierre contable")
        XCTAssertEqual(
            detect("Lo m\u{00E1}s importante es cerrar el reporte.")?.subject,
            "cerrar el reporte")
        // "si" is the conditional and abstains; the accented one is agreement.
        XCTAssertNil(detect("Si la prioridad es el reporte, movemos todo."))
        XCTAssertEqual(
            detect("S\u{00ED}, la prioridad es el reporte.")?.subject,
            "el reporte")
    }

    // MARK: - Regressions found by measuring against real transcripts

    func testADemonstrativeSubjectNamesNothing() {
        XCTAssertNil(
            detect("Y ahorita la prioridad es esta."),
            "a bare demonstrative points at something the detector cannot see")
        XCTAssertNil(detect("The priority is this."))
    }

    func testJoiningNeverExtendsAClauseThatAlreadyHasItsCopula() {
        // Measured failure: the first caption is a complete declaration whose
        // subject is correctly rejected as vacuous. Joining it to the next row
        // manufactured a long subject out of the neighbour's unrelated words.
        let captions = [
            caption("Y ahorita la prioridad es esta.", at: 20),
            caption("El reporte de ayer no es lo mismo, hoy toca otra cosa.", at: 22)
        ]

        XCTAssertNil(StatedPriorityDetector.detect(inRecent: captions))
    }

    private func caption(
        _ text: String,
        at startTime: TimeInterval,
        speaker: String? = "S1"
    ) -> PriorityScanCaption {
        PriorityScanCaption(
            id: UUID(),
            text: text,
            startTime: startTime,
            channel: "system",
            speaker: speaker)
    }

    private func detect(_ text: String) -> StatedPriority? {
        StatedPriorityDetector.detect(in: text, rowID: row, statedAt: 107)
    }
}
