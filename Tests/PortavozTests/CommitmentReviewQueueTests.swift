import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentReviewQueueQueryTests: XCTestCase {
    func testQueryRejectsInvalidDateLimitsAndDuplicateMeetingScope() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try CommitmentReviewQueueQuery(
            reviewAt: Date(timeIntervalSinceReferenceDate: .infinity),
            itemLimit: 0)) { error in
            XCTAssertEqual(
                error as? CommitmentReviewQueueQueryError,
                .invalidReviewDate)
        }
        XCTAssertThrowsError(try CommitmentReviewQueueQuery(
            reviewAt: now,
            itemLimit: CommitmentReviewQueueQuery.maximumItemCount + 1)) { error in
            XCTAssertEqual(
                error as? CommitmentReviewQueueQueryError,
                .invalidLimit)
        }
        let meetingID = MeetingID()
        XCTAssertThrowsError(try CommitmentReviewQueueQuery(
            scope: .meetings([meetingID, meetingID]),
            reviewAt: now)) { error in
            XCTAssertEqual(
                error as? CommitmentReviewQueueQueryError,
                .invalidMeetingScope)
        }
        XCTAssertThrowsError(try CommitmentReviewQueueQuery(
            scope: .meetings((0...CommitmentReviewQueueQuery.maximumMeetingScopeCount)
                .map { _ in MeetingID() }),
            reviewAt: now)) { error in
            XCTAssertEqual(
                error as? CommitmentReviewQueueQueryError,
                .invalidMeetingScope)
        }
    }

    func testUseCaseSamplesOneReviewDateAndPreservesBounds() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meetingID = MeetingID()
        let repository = CommitmentReviewQueueRepositoryFake()
        let useCase = LoadCommitmentReviewQueue(
            repository: repository,
            now: { now })

        _ = try await useCase.execute(LoadCommitmentReviewQueueRequest(
            scope: .meetings([meetingID]),
            itemLimit: 17,
            evidenceLimitPerItem: 4))

        let queries = await repository.queries
        let query = try XCTUnwrap(queries.first)
        XCTAssertEqual(query.scope, .meetings([meetingID]))
        XCTAssertEqual(query.reviewAt, now)
        XCTAssertEqual(query.itemLimit, 17)
        XCTAssertEqual(query.evidenceLimitPerItem, 4)
    }
}

final class CommitmentReviewQueueStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testQueueUsesNewestSummaryAndOnlyReviewableUnconfirmedSources() async throws {
        let fixture = try await makeQueueFixture()

        let page = try await fixture.store.commitmentReviewQueue(
            CommitmentReviewQueueQuery(
                reviewAt: now,
                evidenceLimitPerItem: 1))

        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.items.map(\.id), [fixture.due.id, fixture.pending.id])
        let due = try XCTUnwrap(page.items.first)
        XCTAssertEqual(due.reason, .deferredDue(revisitAt: now))
        XCTAssertEqual(due.meetingID, fixture.meeting.id)
        XCTAssertEqual(due.meetingTitle, "Planning review")
        XCTAssertEqual(due.evidence.status, .current)
        XCTAssertEqual(due.evidence.segments.map(\.id), [fixture.segments[0].id])
        XCTAssertEqual(due.evidenceCount, 2)
        XCTAssertTrue(due.hasMoreEvidence)
        XCTAssertEqual(due.suggestedOwner?.personID, fixture.personID)
        XCTAssertEqual(due.suggestedOwner?.displayName, "Ana")
        XCTAssertFalse(page.hasMore)

        let boundedPage = try await fixture.store.commitmentReviewQueue(
            CommitmentReviewQueueQuery(
                reviewAt: now,
                itemLimit: 1,
                evidenceLimitPerItem: 1))
        XCTAssertEqual(boundedPage.items.map(\.id), [fixture.due.id])
        XCTAssertEqual(boundedPage.totalCount, 2)
        XCTAssertTrue(boundedPage.hasMore)
    }

    func testMeetingScopeAndEvidenceFreshnessFailClosed() async throws {
        let fixture = try await makeQueueFixture()
        let other = Meeting(
            title: "Other meeting",
            startedAt: now.addingTimeInterval(-2_000),
            endedAt: now.addingTimeInterval(-1_000))
        try await fixture.store.save(other)
        let otherSpeaker = Speaker(meetingID: other.id, label: "S1")
        let otherSegment = TranscriptSegment(
            meetingID: other.id,
            speakerID: otherSpeaker.id,
            channel: .system,
            text: "I will publish the notes.",
            startTime: 1,
            endTime: 2,
            isFinal: true)
        try await fixture.store.save([otherSpeaker])
        try await fixture.store.save([otherSegment])
        let otherItem = ActionItem(text: "Publish the notes")
        _ = try await fixture.store.saveSummary(SummaryDraft(
            meetingID: other.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Publish the notes.",
            actionItems: [otherItem],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: otherItem.id,
                evidenceSegmentIDs: [otherSegment.id])]))

        var changedMeeting = fixture.meeting
        changedMeeting.transcriptRevision = 1
        try await fixture.store.save(changedMeeting)
        let scoped = try await fixture.store.commitmentReviewQueue(
            CommitmentReviewQueueQuery(
                scope: .meetings([fixture.meeting.id]),
                reviewAt: now))
        XCTAssertEqual(scoped.totalCount, 2)
        XCTAssertTrue(scoped.items.allSatisfy { $0.meetingID == fixture.meeting.id })
        XCTAssertTrue(scoped.items.allSatisfy {
            $0.evidence.status == .stale && $0.evidence.segments.isEmpty
        })

        let empty = try await fixture.store.commitmentReviewQueue(
            CommitmentReviewQueueQuery(
                scope: .meetings([]),
                reviewAt: now))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.totalCount, 0)
    }

    func testQueueUsesTwoSelectsIndependentOfRootCount() async throws {
        let fixture = try await makeQueueFixture()
        let counter = CommitmentReviewQueueStatementCounter()
        try await fixture.store.database.write { database in
            database.trace(options: .statement) { counter.record($0) }
        }

        _ = try await fixture.store.commitmentReviewQueue(
            CommitmentReviewQueueQuery(reviewAt: now))

        try await fixture.store.database.write { database in
            database.trace(options: [])
        }
        XCTAssertEqual(counter.readStatementCount, 2)
    }

    private func makeQueueFixture() async throws -> CommitmentReviewQueueFixture {
        let store = try MeetingStore.inMemory()
        let context = try await makeMeetingContext(in: store)
        let candidates = try await makeReviewCandidates(
            in: store,
            context: context)
        return CommitmentReviewQueueFixture(
            store: store,
            meeting: context.meeting,
            segments: context.segments,
            pending: candidates.pending,
            due: candidates.due,
            personID: context.personID)
    }

    private func makeMeetingContext(
        in store: MeetingStore
    ) async throws -> CommitmentReviewQueueMeetingContext {
        let meeting = Meeting(
            title: "Planning review",
            startedAt: now.addingTimeInterval(-3_600),
            endedAt: now.addingTimeInterval(-1_800))
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "I will publish the rollout.",
                startTime: 1,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "I will send it tomorrow.",
                startTime: 2,
                endTime: 3,
                isFinal: true)
        ]
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        let person = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName)

        return CommitmentReviewQueueMeetingContext(
            meeting: meeting,
            speaker: speaker,
            segments: segments,
            personID: person.person.id)
    }

    private func makeReviewCandidates(
        in store: MeetingStore,
        context: CommitmentReviewQueueMeetingContext
    ) async throws -> CommitmentReviewQueueCandidates {
        let meeting = context.meeting
        let speaker = context.speaker
        let segments = context.segments

        let superseded = ActionItem(text: "Superseded item")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Old",
            actionItems: [superseded],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: superseded.id,
                evidenceSegmentIDs: [segments[0].id])]))

        let pending = ActionItem(
            text: "Publish the rollout",
            ownerSpeakerID: speaker.id)
        let due = ActionItem(
            text: "Send the rollout note",
            ownerSpeakerID: speaker.id)
        let future = ActionItem(text: "Review next week")
        let dismissed = ActionItem(text: "Ignore this")
        let confirmed = ActionItem(text: "Already confirmed")
        let done = ActionItem(text: "Generated task done", isDone: true)
        let unsupported = ActionItem(text: "No evidence")
        let currentItems = [pending, due, future, dismissed, confirmed, done, unsupported]
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.planning.id,
            language: "en",
            markdown: "Current",
            actionItems: currentItems,
            actionItemEvidence: currentItems.dropLast().map { item in
                SummaryActionItemEvidence(
                    actionItemID: item.id,
                    evidenceSegmentIDs: segments.map(\.id))
            }))
        let decisionAt = now.addingTimeInterval(-100)
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: due.id,
            meetingID: meeting.id,
            revisitAt: now,
            at: decisionAt)
        try await store.setCommitmentReviewDecision(
            .deferred,
            for: future.id,
            meetingID: meeting.id,
            revisitAt: now.addingTimeInterval(100),
            at: decisionAt)
        try await store.setCommitmentReviewDecision(
            .dismissed,
            for: dismissed.id,
            meetingID: meeting.id,
            at: decisionAt)
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: confirmed.text,
                origin: .generatedActionItem(confirmed.id)),
            at: now.addingTimeInterval(-50))
        return CommitmentReviewQueueCandidates(pending: pending, due: due)
    }
}

private struct CommitmentReviewQueueMeetingContext {
    let meeting: Meeting
    let speaker: Speaker
    let segments: [TranscriptSegment]
    let personID: PersonID
}

private struct CommitmentReviewQueueCandidates {
    let pending: ActionItem
    let due: ActionItem
}

private struct CommitmentReviewQueueFixture {
    let store: MeetingStore
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let pending: ActionItem
    let due: ActionItem
    let personID: PersonID
}

private actor CommitmentReviewQueueRepositoryFake: CommitmentReviewQueueReading {
    private(set) var queries: [CommitmentReviewQueueQuery] = []

    func commitmentReviewQueue(
        _ query: CommitmentReviewQueueQuery
    ) -> CommitmentReviewQueuePage {
        queries.append(query)
        return CommitmentReviewQueuePage(items: [], totalCount: 0)
    }
}

private final class CommitmentReviewQueueStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var statements = 0

    var readStatementCount: Int {
        lock.withLock { statements }
    }

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard sql.hasPrefix("SELECT") || sql.hasPrefix("WITH") else { return }
        lock.withLock { statements += 1 }
    }
}
