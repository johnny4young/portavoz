import ApplicationKit
import PortavozCore
import StorageKit
import XCTest

final class SummarySpeakerRenameTests: XCTestCase {
    private let meetingID = MeetingID()

    private func draft(
        markdown: String,
        items: [ActionItem] = [],
        evidence: [SummaryActionItemEvidence] = []
    ) -> SummaryDraft {
        SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: markdown,
            actionItems: items,
            fingerprint: "cached",
            actionItemEvidence: evidence)
    }

    func testReplacesWholeWordsOnly() throws {
        let source = draft(markdown: "Ana and Anabel agreed. Ana owns it.\n- [ ] Send deck — Ana")

        let renamed = try XCTUnwrap(SummarySpeakerRename.renamed(source, from: "Ana", to: "Ana Ruiz"))

        XCTAssertEqual(
            renamed.markdown,
            "Ana Ruiz and Anabel agreed. Ana Ruiz owns it.\n- [ ] Send deck — Ana Ruiz")
        XCTAssertNil(renamed.fingerprint)
    }

    func testNameWithPatternCharactersIsLiteral() throws {
        let source = draft(markdown: "Speaker 2 (guest) spoke; Speaker 22 did not.")

        let renamed = try XCTUnwrap(
            SummarySpeakerRename.renamed(source, from: "Speaker 2", to: "$1 Leo"))

        XCTAssertEqual(renamed.markdown, "$1 Leo (guest) spoke; Speaker 22 did not.")
    }

    func testUnchangedSummaryIsNotRewritten() {
        let source = draft(markdown: "Nobody named here.")

        XCTAssertNil(SummarySpeakerRename.renamed(source, from: "Ana", to: "Bea"))
        XCTAssertNil(SummarySpeakerRename.renamed(source, from: "Ana", to: "Ana"))
        XCTAssertNil(SummarySpeakerRename.renamed(source, from: " ", to: "Bea"))
    }

    func testActionItemsGetFreshIdentitiesAndKeepTheirState() throws {
        let owner = SpeakerID()
        let item = ActionItem(text: "Ana sends the deck", ownerSpeakerID: owner, isDone: true)
        let source = draft(
            markdown: "Overview.",
            items: [item],
            evidence: [SummaryActionItemEvidence(actionItemID: item.id, evidenceSegmentIDs: [UUID()])])

        let renamed = try XCTUnwrap(SummarySpeakerRename.renamed(source, from: "Ana", to: "Bea"))

        let next = try XCTUnwrap(renamed.actionItems.first)
        XCTAssertEqual(next.text, "Bea sends the deck")
        XCTAssertEqual(next.ownerSpeakerID, owner)
        XCTAssertTrue(next.isDone)
        XCTAssertNotEqual(next.id, item.id)
        XCTAssertEqual(renamed.actionItemEvidence.map(\.actionItemID), [next.id])
    }

    func testStoreSavesTheRenameAsTheNextVersionOnItsOriginalRun() async throws {
        let store = try MeetingStore.inMemory()
        try await store.save(Meeting(id: meetingID, title: "Sync", startedAt: Date()))
        let item = ActionItem(text: "Ana books the room", isDone: true)
        let version = try await store.saveSummary(
            draft(markdown: "Ana opened.\n- [ ] Ana books the room", items: [item]))
        let useCase = ApplySpeakerRenameToSummary(store: store)

        let saved = try await useCase.execute(meetingID: meetingID, from: "Ana", to: "Bea")
        let untouched = try await useCase.execute(meetingID: meetingID, from: "Carl", to: "Dan")

        let stored = try await store.mostRecentSummary(meetingID)
        let current = try XCTUnwrap(stored)
        XCTAssertEqual(saved, version + 1)
        XCTAssertNil(untouched)
        XCTAssertEqual(current.version, version + 1)
        XCTAssertEqual(current.draft.markdown, "Bea opened.\n- [ ] Bea books the room")
        XCTAssertEqual(current.draft.actionItems.map(\.text), ["Bea books the room"])
        XCTAssertEqual(current.draft.actionItems.map(\.isDone), [true])
        let open = try await store.openActionItems()
        XCTAssertTrue(open.isEmpty)
    }
}
