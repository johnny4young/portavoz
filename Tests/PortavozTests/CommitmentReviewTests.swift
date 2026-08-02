import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentReviewPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDispositionRequiresCanonicalDeadlineShape() throws {
        let actionItemID = UUID()
        XCTAssertNoThrow(try CommitmentReviewPolicy.validate(
            CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .dismissed,
                updatedAt: now)))
        XCTAssertThrowsError(try CommitmentReviewPolicy.validate(
            CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .dismissed,
                revisitAt: now.addingTimeInterval(1),
                updatedAt: now)))
        XCTAssertThrowsError(try CommitmentReviewPolicy.validate(
            CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .deferred,
                updatedAt: now)))
        XCTAssertThrowsError(try CommitmentReviewPolicy.validate(
            CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .deferred,
                revisitAt: now,
                updatedAt: now)))
    }

    func testDeferredSourceReturnsToPendingAtExactRevisitDate() throws {
        let actionItemID = UUID()
        let revisitAt = now.addingTimeInterval(60)
        let state = CommitmentReviewState(
            actionItemID: actionItemID,
            decision: CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .deferred,
                revisitAt: revisitAt,
                updatedAt: now))

        XCTAssertFalse(CommitmentReviewPolicy.isPending(
            state,
            at: revisitAt.addingTimeInterval(-0.001)))
        XCTAssertTrue(CommitmentReviewPolicy.isPending(state, at: revisitAt))
    }

    func testConfirmedAndReviewFeedbackCannotCoexist() throws {
        let actionItemID = UUID()
        let event = CommitmentEvent(
            commitmentID: CommitmentID(),
            kind: .confirm,
            occurredAt: now)
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: event.commitmentID,
            title: "Publish the rollout",
            events: [event])
        let state = CommitmentReviewState(
            actionItemID: actionItemID,
            decision: CommitmentReviewDecision(
                actionItemID: actionItemID,
                disposition: .dismissed,
                updatedAt: now),
            commitment: commitment)

        XCTAssertThrowsError(try CommitmentReviewPolicy.validate(state))
    }
}

final class CommitmentInboxProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProjectionRequiresEvidenceAndExactLinkedPerson() throws {
        let meeting = Meeting(title: "Planning", startedAt: now)
        let personID = PersonID()
        let linked = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana",
            personID: personID)
        let conflictingDuplicate = Speaker(
            id: linked.id,
            meetingID: meeting.id,
            label: "S1 duplicate",
            displayName: "Wrong",
            personID: PersonID())
        let unlinked = Speaker(
            meetingID: meeting.id,
            label: "S2",
            displayName: "Bea")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: linked.id,
            channel: .system,
            text: "I will publish the rollout.",
            startTime: 1,
            endTime: 3,
            isFinal: true)
        let linkedItem = ActionItem(
            text: "Publish the rollout",
            ownerSpeakerID: linked.id)
        let unlinkedItem = ActionItem(
            text: "Review the rollout",
            ownerSpeakerID: unlinked.id)
        let unsupportedItem = ActionItem(text: "Invent a deadline")
        let completedItem = ActionItem(text: "Already done", isDone: true)
        let draft = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## Summary",
            actionItems: [linkedItem, unlinkedItem, unsupportedItem, completedItem],
            actionItemEvidence: [linkedItem, unlinkedItem, completedItem].map {
                SummaryActionItemEvidence(
                    actionItemID: $0.id,
                    sourceTranscriptRevision: 0,
                    evidenceSegmentIDs: [segment.id])
            })
        let deferredUntil = now.addingTimeInterval(3_600)
        let review = MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [linked, conflictingDuplicate, unlinked],
                segments: [segment]),
            summary: MeetingReviewSummary(draft: draft, version: 1),
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [],
            commitmentReviewStates: [
                CommitmentReviewState(
                    actionItemID: unlinkedItem.id,
                    decision: CommitmentReviewDecision(
                        actionItemID: unlinkedItem.id,
                        disposition: .deferred,
                        revisitAt: deferredUntil,
                        updatedAt: now)),
            ])

        let candidates = review.commitmentInboxCandidates(at: now)

        XCTAssertEqual(candidates.map(\.id), [linkedItem.id, unlinkedItem.id])
        XCTAssertEqual(candidates[0].evidence.status, .current)
        XCTAssertEqual(candidates[0].suggestedOwner?.personID, personID)
        XCTAssertEqual(candidates[0].suggestedOwner?.displayName, "Ana")
        XCTAssertNil(candidates[0].suggestedDueAt)
        XCTAssertNil(candidates[1].suggestedOwner)
        XCTAssertEqual(candidates[1].status, .deferred(until: deferredUntil))
    }
}

final class CommitmentReviewStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchemaV21StoresOnlySourceBoundReviewFeedback() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v20")
        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 21)
            XCTAssertEqual(
                try Set(database.columns(in: "commitmentReviewDecision").map(\.name)),
                [
                    "actionItemID", "disposition", "revisitAt", "createdAt",
                    "updatedAt", "deletedAt",
                ])
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM commitmentReviewDecision"),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM sqlite_master
                        WHERE type = 'index'
                          AND name = 'commitmentSource_unique_actionItem'
                        """),
                1)
        }
    }

    func testDismissDeferClearAndObservationRoundTrip() async throws {
        let fixture = try await commitmentReviewFixture()
        var iterator = fixture.store
            .observeCommitmentReviewStates(for: fixture.meeting.id)
            .makeAsyncIterator()
        let initialValue = try await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.count, 1)
        XCTAssertNil(initial[0].decision)

        try await fixture.store.setCommitmentReviewDecision(
            .dismissed,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now)
        let dismissedValue = try await iterator.next()
        let dismissed = try XCTUnwrap(dismissedValue)
        XCTAssertEqual(dismissed.first?.decision?.disposition, .dismissed)

        let revisitAt = now.addingTimeInterval(3_600)
        try await fixture.store.setCommitmentReviewDecision(
            .deferred,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            revisitAt: revisitAt,
            at: now.addingTimeInterval(1))
        let deferredValue = try await iterator.next()
        let deferred = try XCTUnwrap(deferredValue)
        XCTAssertEqual(deferred.first?.decision?.revisitAt, revisitAt)

        try await fixture.store.setCommitmentReviewDecision(
            nil,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now.addingTimeInterval(2))
        let clearedValue = try await iterator.next()
        let cleared = try XCTUnwrap(clearedValue)
        XCTAssertNil(cleared.first?.decision)

        try await fixture.store.setCommitmentReviewDecision(
            .dismissed,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now)
        let reopenedValue = try await iterator.next()
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(reopened.first?.decision?.updatedAt, now.addingTimeInterval(2))
    }

    func testFeedbackRequiresNewestSummaryAndFutureDeferral() async throws {
        let fixture = try await commitmentReviewFixture()
        let foreignMeeting = Meeting(title: "Foreign", startedAt: now)
        try await fixture.store.save(foreignMeeting)

        await expectCommitmentReviewThrow {
            try await fixture.store.setCommitmentReviewDecision(
                .dismissed,
                for: fixture.actionItem.id,
                meetingID: foreignMeeting.id,
                at: self.now)
        }
        await expectCommitmentReviewThrow {
            try await fixture.store.setCommitmentReviewDecision(
                .deferred,
                for: fixture.actionItem.id,
                meetingID: fixture.meeting.id,
                revisitAt: self.now,
                at: self.now)
        }

        let replacement = ActionItem(text: "Publish the replacement")
        _ = try await fixture.store.saveSummary(SummaryDraft(
            meetingID: fixture.meeting.id,
            recipeID: Recipe.planning.id,
            language: "en",
            markdown: "Replacement",
            actionItems: [replacement],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: replacement.id,
                evidenceSegmentIDs: [fixture.segment.id])]))
        await expectCommitmentReviewThrow {
            try await fixture.store.setCommitmentReviewDecision(
                .dismissed,
                for: fixture.actionItem.id,
                meetingID: fixture.meeting.id,
                at: self.now)
        }
        let states = try await fixture.store.commitmentReviewStates(
            for: fixture.meeting.id)
        XCTAssertEqual(states.map(\.actionItemID), [replacement.id])
        XCTAssertNil(states.first?.decision)
    }

    func testConfirmationClearsFeedbackAndRejectsDuplicateSource() async throws {
        let fixture = try await commitmentReviewFixture()
        try await fixture.store.setCommitmentReviewDecision(
            .dismissed,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now)
        let envelope = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: fixture.actionItem.text,
                canonicalPersonID: fixture.personID,
                origin: .generatedActionItem(fixture.actionItem.id)),
            at: now.addingTimeInterval(1))

        let states = try await fixture.store.commitmentReviewStates(
            for: fixture.meeting.id)
        XCTAssertNil(states.first?.decision)
        XCTAssertEqual(states.first?.commitment, envelope.commitment)
        try await fixture.store.database.read { database in
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT deletedAt FROM commitmentReviewDecision
                    WHERE actionItemID = ?
                    """,
                arguments: [fixture.actionItem.id.uuidString])
            XCTAssertNotNil(row?["deletedAt"] as Date?)
        }
        await expectCommitmentReviewThrow {
            _ = try await fixture.store.confirmCommitment(
                CommitmentConfirmation(
                    title: "Duplicate",
                    origin: .generatedActionItem(fixture.actionItem.id)),
                at: self.now.addingTimeInterval(2))
        }
    }

    func testPortableConfirmationReplayClearsDestinationFeedback() async throws {
        let fixture = try await commitmentReviewFixture()
        let envelope = try await fixture.store.confirmCommitment(
            CommitmentConfirmation(
                title: fixture.actionItem.text,
                origin: .generatedActionItem(fixture.actionItem.id)),
            at: now.addingTimeInterval(1))
        let destination = try MeetingStore.inMemory()
        try await destination.save(fixture.meeting)
        try await destination.save([fixture.speaker])
        try await destination.save([fixture.segment])
        _ = try await destination.saveSummary(SummaryDraft(
            meetingID: fixture.meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Ana will publish the rollout.",
            actionItems: [fixture.actionItem],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: fixture.actionItem.id,
                evidenceSegmentIDs: [fixture.segment.id])]))
        try await destination.setCommitmentReviewDecision(
            .dismissed,
            for: fixture.actionItem.id,
            meetingID: fixture.meeting.id,
            at: now)

        _ = try await destination.applyCommitmentContinuityEnvelope(envelope)

        let states = try await destination.commitmentReviewStates(for: fixture.meeting.id)
        let state = try XCTUnwrap(states.first)
        XCTAssertNil(state.decision)
        XCTAssertEqual(state.commitment, envelope.commitment)
    }
}

private struct CommitmentReviewFixture {
    let store: MeetingStore
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let actionItem: ActionItem
    let personID: PersonID
}

private func commitmentReviewFixture() async throws -> CommitmentReviewFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MeetingStore.inMemory()
    let meeting = Meeting(title: "Planning", startedAt: now)
    let speaker = Speaker(
        meetingID: meeting.id,
        label: "S1",
        displayName: "Ana")
    let segment = TranscriptSegment(
        meetingID: meeting.id,
        speakerID: speaker.id,
        channel: .system,
        text: "I will publish the rollout.",
        startTime: 1,
        endTime: 3,
        isFinal: true)
    try await store.save(meeting)
    try await store.save([speaker])
    try await store.save([segment])
    let person = try await store.createPersonAndLink(
        speakerID: speaker.id,
        preferredName: "Ana",
        source: .manualName)
    let actionItem = ActionItem(
        text: "Publish the rollout",
        ownerSpeakerID: speaker.id)
    _ = try await store.saveSummary(SummaryDraft(
        meetingID: meeting.id,
        recipeID: Recipe.general.id,
        language: "en",
        markdown: "Ana will publish the rollout.",
        actionItems: [actionItem],
        actionItemEvidence: [SummaryActionItemEvidence(
            actionItemID: actionItem.id,
            evidenceSegmentIDs: [segment.id])]))
    return CommitmentReviewFixture(
        store: store,
        meeting: meeting,
        speaker: speaker,
        segment: segment,
        actionItem: actionItem,
        personID: person.person.id)
}

private func expectCommitmentReviewThrow(
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
