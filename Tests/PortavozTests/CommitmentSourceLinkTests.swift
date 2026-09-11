import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentSourceLinkTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_600_000)

    func testExplicitLinkAppendsCrossMeetingEvidenceWithoutChangingLifecycle() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await generatedSource(
            in: store,
            meetingTitle: "Initial planning",
            startedAt: baseDate,
            transcript: "I will prepare the rollout.",
            action: "Prepare the rollout")
        let initial = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                origin: .generatedActionItem(first.actionItemID)),
            at: baseDate.addingTimeInterval(60))

        let followUp = try await generatedSource(
            in: store,
            meetingTitle: "Follow-up",
            startedAt: baseDate.addingTimeInterval(86_400),
            transcript: "The rollout preparation is still in progress.",
            action: "Continue preparing the rollout")
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: followUp.actionItemID,
            meetingID: followUp.meeting.id,
            revisitAt: baseDate.addingTimeInterval(10 * 86_400),
            at: baseDate.addingTimeInterval(2 * 86_400))

        let linked = try await store.linkCommitmentSource(
            CommitmentLinkConfirmation(
                commitmentID: initial.commitment.id,
                sourceMeetingID: followUp.meeting.id,
                actionItemID: followUp.actionItemID),
            at: baseDate.addingTimeInterval(3 * 86_400))

        XCTAssertEqual(linked.commitment, initial.commitment)
        XCTAssertEqual(linked.events, initial.events)
        XCTAssertEqual(linked.sources.count, 2)
        XCTAssertEqual(linked.sources.last?.meetingID, followUp.meeting.id)
        XCTAssertEqual(linked.sources.last?.actionItemID, followUp.actionItemID)
        XCTAssertEqual(linked.sources.last?.evidence.map(\.segmentID), [followUp.segmentID])
        let followUpReview = try await store.commitmentReviewStates(
            for: followUp.meeting.id)
        XCTAssertNil(followUpReview.first?.decision)
        XCTAssertEqual(followUpReview.first?.commitment, initial.commitment)
        let linkedCounts = try await continuityCounts(in: store)
        XCTAssertEqual(linkedCounts, [1, 2, 2, 1])

        await assertThrows {
            _ = try await store.linkCommitmentSource(
                CommitmentLinkConfirmation(
                    commitmentID: initial.commitment.id,
                    sourceMeetingID: followUp.meeting.id,
                    actionItemID: followUp.actionItemID),
                at: self.baseDate.addingTimeInterval(4 * 86_400))
        }
        let retryCounts = try await continuityCounts(in: store)
        XCTAssertEqual(retryCounts, [1, 2, 2, 1])
    }

    func testLinkFailsClosedForWrongMeetingSameMeetingAndClosedCommitment() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await generatedSource(
            in: store,
            meetingTitle: "Initial planning",
            startedAt: baseDate,
            transcript: "I will prepare the rollout.",
            action: "Prepare the rollout")
        let initial = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                origin: .generatedActionItem(first.actionItemID)),
            at: baseDate.addingTimeInterval(60))
        let sameMeeting = try await generatedSource(
            in: store,
            meeting: first.meeting,
            transcript: "I will also verify the rollout.",
            action: "Verify the rollout")

        await assertThrows {
            _ = try await store.linkCommitmentSource(
                CommitmentLinkConfirmation(
                    commitmentID: initial.commitment.id,
                    sourceMeetingID: MeetingID(),
                    actionItemID: sameMeeting.actionItemID),
                at: self.baseDate.addingTimeInterval(120))
        }
        await assertThrows {
            _ = try await store.linkCommitmentSource(
                CommitmentLinkConfirmation(
                    commitmentID: initial.commitment.id,
                    sourceMeetingID: first.meeting.id,
                    actionItemID: sameMeeting.actionItemID),
                at: self.baseDate.addingTimeInterval(120))
        }
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: initial.commitment.id,
            at: baseDate.addingTimeInterval(180))
        let later = try await generatedSource(
            in: store,
            meetingTitle: "Later follow-up",
            startedAt: baseDate.addingTimeInterval(86_400),
            transcript: "The rollout work is complete.",
            action: "Review the completed rollout")
        await assertThrows {
            _ = try await store.linkCommitmentSource(
                CommitmentLinkConfirmation(
                    commitmentID: initial.commitment.id,
                    sourceMeetingID: later.meeting.id,
                    actionItemID: later.actionItemID),
                at: self.baseDate.addingTimeInterval(2 * 86_400))
        }

        let rejectedCounts = try await continuityCounts(in: store)
        XCTAssertEqual(rejectedCounts, [1, 1, 1, 2])
    }

    func testLinkRejectsRetiredSummarySourceWithoutWrites() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await generatedSource(
            in: store,
            meetingTitle: "Initial planning",
            startedAt: baseDate,
            transcript: "I will prepare the rollout.",
            action: "Prepare the rollout")
        let initial = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                origin: .generatedActionItem(first.actionItemID)),
            at: baseDate.addingTimeInterval(60))
        let retired = try await generatedSource(
            in: store,
            meetingTitle: "Follow-up",
            startedAt: baseDate.addingTimeInterval(86_400),
            transcript: "I will validate the rollout.",
            action: "Validate the rollout")
        _ = try await generatedSource(
            in: store,
            meeting: retired.meeting,
            transcript: "I will publish the rollout report.",
            action: "Publish the rollout report")

        await assertThrows {
            _ = try await store.linkCommitmentSource(
                CommitmentLinkConfirmation(
                    commitmentID: initial.commitment.id,
                    sourceMeetingID: retired.meeting.id,
                    actionItemID: retired.actionItemID),
                at: self.baseDate.addingTimeInterval(2 * 86_400))
        }

        let rejectedCounts = try await continuityCounts(in: store)
        XCTAssertEqual(rejectedCounts, [1, 1, 1, 1])
    }

    func testLinkCanonicalizesRegressedClockAfterCurrentHistory() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await generatedSource(
            in: store,
            meetingTitle: "Initial planning",
            startedAt: baseDate,
            transcript: "I will prepare the rollout.",
            action: "Prepare the rollout")
        let initial = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Prepare the rollout",
                origin: .generatedActionItem(first.actionItemID)),
            at: baseDate.addingTimeInterval(60))
        let current = try await store.applyCommitmentTransition(
            .reschedule(baseDate.addingTimeInterval(86_400)),
            to: initial.commitment.id,
            at: baseDate.addingTimeInterval(120))
        let followUp = try await generatedSource(
            in: store,
            meetingTitle: "Follow-up",
            startedAt: baseDate.addingTimeInterval(86_400),
            transcript: "The rollout is scheduled.",
            action: "Keep the rollout scheduled")

        let linked = try await store.linkCommitmentSource(
            CommitmentLinkConfirmation(
                commitmentID: initial.commitment.id,
                sourceMeetingID: followUp.meeting.id,
                actionItemID: followUp.actionItemID),
            at: baseDate)

        XCTAssertEqual(linked.commitment, current.commitment)
        XCTAssertEqual(
            linked.sources.last?.firstSeenAt,
            current.commitment.updatedAt.addingTimeInterval(0.001))
        let reloaded = try await store.commitmentContinuityEnvelope(
            for: initial.commitment.id)
        XCTAssertEqual(reloaded, linked)
    }

    private func generatedSource(
        in store: MeetingStore,
        meetingTitle: String,
        startedAt: Date,
        transcript: String,
        action: String
    ) async throws -> GeneratedSource {
        let meeting = Meeting(title: meetingTitle, startedAt: startedAt)
        try await store.save(meeting)
        return try await generatedSource(
            in: store,
            meeting: meeting,
            transcript: transcript,
            action: action)
    }

    private func generatedSource(
        in store: MeetingStore,
        meeting: Meeting,
        transcript: String,
        action: String
    ) async throws -> GeneratedSource {
        let speaker = Speaker(meetingID: meeting.id, label: "S1")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: transcript,
            startTime: 1,
            endTime: 4,
            isFinal: true)
        try await store.save([speaker])
        try await store.save([segment])
        let item = ActionItem(text: action, ownerSpeakerID: speaker.id)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: transcript,
            actionItems: [item],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: item.id,
                evidenceSegmentIDs: [segment.id])]))
        return GeneratedSource(
            meeting: meeting,
            actionItemID: item.id,
            segmentID: segment.id)
    }
}

private struct GeneratedSource {
    let meeting: Meeting
    let actionItemID: UUID
    let segmentID: UUID
}

private func continuityCounts(in store: MeetingStore) async throws -> [Int] {
    try await store.database.read { database in
        try [
            "commitment", "commitmentSource", "commitmentEvidenceSegment",
            "commitmentEvent"
        ].map { table in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }
}

private func assertThrows(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
