import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class MeetingMarginNotesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let meeting = Meeting(title: "Planning", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    private lazy var me = Speaker(meetingID: meeting.id, label: "S1", isMe: true)
    private lazy var ana = Speaker(meetingID: meeting.id, label: "S2", displayName: "Ana", personID: PersonID())
    private lazy var opening = line("Let us start.", speaker: me, at: 0)
    private lazy var decided = line("The rollout ships on Friday.", speaker: ana, at: 4)

    func testDecisionsAndCommitmentsSitBesideTheirFirstEvidenceLine() {
        let item = ActionItem(text: "Prepare the rollout", ownerSpeakerID: ana.id)
        let notes = review(items: [item], evidence: [decided.id]).marginNotes(in: content(), at: now)

        XCTAssertTrue(notes.notes(forRow: opening.id).isEmpty)
        let row = notes.notes(forRow: decided.id)
        XCTAssertEqual(row.map(\.id), ["decision-\(decisionID.rawValue.uuidString)", "commitment-\(item.id.uuidString)"])
        guard case .decision(_, let statement) = row[0].kind else { return XCTFail("decision first") }
        XCTAssertEqual(statement, "▸ The rollout ships on Friday.", "the exact bullet text, as the summary confirms it")
        guard case .commitment(let commitment) = row[1].kind else { return XCTFail("commitment second") }
        XCTAssertNotNil(commitment.candidate, "a pending item can be confirmed from its card")
        XCTAssertEqual(commitment.source.saidBy?.displayName, "Ana")
        XCTAssertEqual(commitment.source.owner?.displayName, "Ana")
        XCTAssertTrue(commitment.source.ownerSaidIt)
        XCTAssertEqual(notes.anchoredItemIDs, [item.id])
        XCTAssertTrue(
            notes.inbox(review(items: [item], evidence: [decided.id]).commitmentInboxCandidates(at: now)).isEmpty,
            "an anchored commitment leaves the inbox")
    }

    func testConfirmedOwnerAndDueDateWinAndDismissedItemsLeaveTheMargin() {
        let confirmed = ActionItem(text: "Ship it", ownerSpeakerID: ana.id)
        let dismissed = ActionItem(text: "Not a commitment")
        let done = ActionItem(text: "Already done", isDone: true)
        let due = now.addingTimeInterval(86_400)
        let notes = review(
            items: [confirmed, dismissed, done],
            evidence: [decided.id],
            states: [
                CommitmentReviewState(
                    actionItemID: confirmed.id,
                    commitment: Commitment(title: "Ship it", assignee: .me, dueAt: due, createdAt: now)),
                CommitmentReviewState(
                    actionItemID: dismissed.id,
                    decision: CommitmentReviewDecision(
                        actionItemID: dismissed.id, disposition: .dismissed, updatedAt: now)),
            ]
        ).marginNotes(in: content(), at: now)

        let commitments = notes.notes(forRow: decided.id).compactMap { note -> MeetingMarginNote.Commitment? in
            if case .commitment(let commitment) = note.kind { return commitment }
            return nil
        }
        XCTAssertEqual(commitments.map(\.item.id), [confirmed.id, done.id])
        XCTAssertNil(commitments[0].candidate, "a confirmed item no longer asks to be confirmed")
        XCTAssertEqual(commitments[0].source.owner?.isMe, true, "the confirmed assignee replaces the proposal")
        XCTAssertEqual(commitments[0].source.dueAt, due)
        XCTAssertFalse(commitments[0].source.ownerSaidIt, "Ana said it, you own it")
        XCTAssertNil(commitments[1].candidate, "a done item keeps its card without review actions")
    }

    func testAnEvidenceLineThatIsNoLongerShownFallsToTheNextOne() {
        let item = ActionItem(text: "Prepare the rollout")
        let notes = review(items: [item], evidence: [opening.id, decided.id])
            .marginNotes(in: content(rows: [decided]), at: now)
        XCTAssertEqual(notes.notes(forRow: decided.id).count, 2)
        XCTAssertNil(notes.byRow[opening.id])

        let unshown = review(items: [item], evidence: [opening.id])
        let unanchored = unshown.marginNotes(in: content(rows: [decided]), at: now)
        XCTAssertEqual(
            unanchored.inbox(unshown.commitmentInboxCandidates(at: now)).map(\.id), [item.id],
            "a candidate whose only line is hidden stays in the inbox")
    }

    func testAStaleSummaryAnchorsNothing() {
        let item = ActionItem(text: "Prepare the rollout")
        let notes = review(items: [item], evidence: [decided.id], revision: 7).marginNotes(in: content(), at: now)
        XCTAssertTrue(notes.byRow.isEmpty)
        XCTAssertTrue(notes.anchoredItemIDs.isEmpty)
    }

    // MARK: Fixtures

    private let decisionID = SummaryDecisionID()

    private func line(_ text: String, speaker: Speaker, at start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting.id, speakerID: speaker.id, channel: .system, text: text,
            startTime: start, endTime: start + 3, isFinal: true)
    }

    private func content(rows: [TranscriptSegment]? = nil) -> MeetingTranscriptContent {
        MeetingTranscriptContent.accepted(
            baseTranscriptRevision: 0, segments: rows ?? [opening, decided], chapterTitles: [:])
    }

    private func review(
        items: [ActionItem],
        evidence: [UUID],
        states: [CommitmentReviewState] = [],
        revision: Int = 0
    ) -> MeetingReviewReadModel {
        let draft = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Overview.\n\n## Decisions\n- ▸ The rollout ships on Friday.",
            actionItems: items,
            decisionEvidence: [SummaryDecisionEvidence(
                id: decisionID, sectionOrdinal: 0, bulletOrdinal: 0,
                sourceTranscriptRevision: revision, evidenceSegmentIDs: evidence)],
            actionItemEvidence: items.map {
                SummaryActionItemEvidence(
                    actionItemID: $0.id, sourceTranscriptRevision: revision, evidenceSegmentIDs: evidence)
            })
        return MeetingReviewReadModel(
            core: MeetingReviewCore(meeting: meeting, speakers: [me, ana], segments: [opening, decided]),
            summary: MeetingReviewSummary(draft: draft, version: 1),
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [],
            commitmentReviewStates: states)
    }
}
