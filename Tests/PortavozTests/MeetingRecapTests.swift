@testable import ApplicationKit
import PortavozCore
import XCTest

/// FEATURE-003/D136: the recap is a summary-derived, reviewable draft.
final class MeetingRecapTests: XCTestCase {
    func testRecapCarriesSummaryContentAndOpenCommitmentsWithOwners() {
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(),
            timeZone: .gmt)

        XCTAssertTrue(recap.subject.contains("Budget review"))
        XCTAssertTrue(
            recap.subject.contains("2026"),
            "a recap subject dates the meeting, saw: \(recap.subject)")
        XCTAssertTrue(recap.markdown.contains("The team agreed on the rollout."))
        XCTAssertTrue(recap.markdown.contains("## Decisions"))
        XCTAssertTrue(recap.markdown.contains("- Ship on Friday."))
        XCTAssertTrue(recap.markdown.contains("## Open commitments"))
        XCTAssertTrue(recap.markdown.contains("- Ana: prepare the rollout"))
        XCTAssertTrue(
            recap.markdown.contains("- Write the release note"),
            "an unowned commitment still belongs in the recap")
        XCTAssertFalse(
            recap.markdown.contains("already done"),
            "a recap looks forward: closed commitments are not repeated")
    }

    func testActionItemSectionFromTheSnapshotNeverDuplicatesTheRealOne() {
        let fixture = Fixture()
        let summary = fixture.summary(markdown: """
            The team agreed on the rollout.

            ## Decisions
            - Ship on Friday.

            ## Next Steps
            - [ ] a STALE copy the model narrated
            """)

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: summary,
            timeZone: .gmt)

        XCTAssertFalse(
            recap.markdown.contains("STALE"),
            "commitments are re-rendered from the library's real done state")
        XCTAssertTrue(recap.markdown.contains("- Ana: prepare the rollout"))
    }

    func testParticipantAudienceLeadsWithTheirOwnCommitments() {
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(),
            audience: .participant(fixture.ana.id),
            timeZone: .gmt)

        let mine = try? XCTUnwrap(recap.markdown.range(of: "## Your commitments"))
        let others = try? XCTUnwrap(recap.markdown.range(of: "## Other commitments"))
        XCTAssertNotNil(mine)
        XCTAssertNotNil(others)
        if let mine, let others {
            XCTAssertTrue(mine.lowerBound < others.lowerBound, "your items come first")
        }
        XCTAssertTrue(
            recap.markdown.contains("- prepare the rollout"),
            "your own section drops the redundant owner prefix")
        XCTAssertFalse(recap.markdown.contains("- Ana: prepare the rollout"))
        XCTAssertTrue(recap.markdown.contains("- Write the release note"))
    }

    func testParticipantWithoutCommitmentsIsToldSoInsteadOfSeeingAnEmptyList() {
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(),
            audience: .participant(fixture.me.id),
            timeZone: .gmt)

        XCTAssertTrue(recap.markdown.contains("Nothing is assigned to you."))
        XCTAssertTrue(
            recap.markdown.contains("## Other commitments"),
            "the rest of the room's commitments stay visible")
    }

    func testAllCommitmentsClosedSaysSoRatherThanPrintingAnEmptyHeading() {
        let fixture = Fixture()
        let done = ActionItem(
            text: "prepare the rollout", ownerSpeakerID: fixture.ana.id, isDone: true)

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(actionItems: [done]),
            timeZone: .gmt)

        XCTAssertTrue(recap.markdown.contains("Nothing was left open."))
        XCTAssertFalse(recap.markdown.contains("prepare the rollout"))
    }

    func testSpanishSummaryProducesASpanishRecap() {
        let fixture = Fixture()
        let summary = fixture.summary(
            language: "es",
            markdown: """
                El equipo fijó el rollout.

                ## Decisiones
                - Sale el viernes.
                """)

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: summary,
            timeZone: .gmt)

        XCTAssertTrue(recap.subject.hasPrefix("Resumen de la reunión:"))
        XCTAssertTrue(recap.markdown.contains("## Pendientes"))
        XCTAssertTrue(recap.markdown.contains("## Decisiones"))
        XCTAssertTrue(
            recap.markdown.contains("No incluye la transcripción."),
            "the recap speaks the MEETING's language, not the interface's")
    }

    func testProvenanceClaimsOnlyWhatIsAlwaysTrue() {
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(),
            timeZone: .gmt)

        XCTAssertTrue(recap.markdown.contains("The transcript is not included."))
        // A BYOK or remote engine may have generated the summary, so the
        // recap must never claim the material stayed on the device.
        XCTAssertFalse(recap.markdown.lowercased().contains("never left"))
        XCTAssertFalse(recap.markdown.lowercased().contains("stayed on"))
    }

    func testEmptySummaryStillProducesAHonestSendableDraft() {
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: fixture.meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(markdown: "", actionItems: []),
            timeZone: .gmt)

        XCTAssertTrue(recap.subject.contains("Budget review"))
        XCTAssertTrue(recap.markdown.contains("Nothing was left open."))
        XCTAssertFalse(
            recap.markdown.contains("## \n"), "no empty headings are emitted")
    }

    func testUntitledMeetingKeepsASendableSubject() {
        var meeting = Fixture().meeting
        meeting.title = "   "
        let fixture = Fixture()

        let recap = RecapComposer.compose(
            meeting: meeting,
            speakers: fixture.speakers,
            summary: fixture.summary(),
            timeZone: .gmt)

        XCTAssertTrue(recap.subject.contains("Untitled meeting"))
    }
}

private struct Fixture {
    let meeting: Meeting
    let me: Speaker
    let ana: Speaker

    var speakers: [Speaker] { [me, ana] }

    init() {
        let meeting = Meeting(
            title: "Budget review",
            startedAt: Date(timeIntervalSince1970: 1_784_000_000))
        self.meeting = meeting
        me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
    }

    func summary(
        language: String = "en",
        markdown: String = """
            The team agreed on the rollout.

            ## Decisions
            - Ship on Friday.
            """,
        actionItems: [ActionItem]? = nil
    ) -> SummaryDraft {
        SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: language,
            markdown: markdown,
            actionItems: actionItems ?? [
                ActionItem(text: "prepare the rollout", ownerSpeakerID: ana.id),
                ActionItem(text: "Write the release note"),
                ActionItem(text: "already done", ownerSpeakerID: ana.id, isDone: true)
            ])
    }
}
