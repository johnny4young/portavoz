import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingDetailObservationTests: XCTestCase {
    func testMeetingReviewObservationsTrackLifecycleAndIndependentContent() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Planning", startedAt: Date())
        var core = store.observeMeetingReviewCore(meeting.id).makeAsyncIterator()
        var summary = store.observeMeetingReviewSummary(meeting.id).makeAsyncIterator()
        var companion = store.observeMeetingReviewCompanionCards(meeting.id).makeAsyncIterator()

        let initialCore = try await nextCore(&core)
        let initialSummary = try await nextSummary(&summary)
        let initialCompanion = try await nextCompanion(&companion)
        XCTAssertNil(initialCore)
        XCTAssertNil(initialSummary)
        XCTAssertTrue(initialCompanion.isEmpty)

        try await store.save(meeting)
        let insertedCore = try await nextCore(&core) { $0?.meeting.id == meeting.id }
        _ = try await nextSummary(&summary)
        _ = try await nextCompanion(&companion)
        XCTAssertEqual(insertedCore?.meeting.title, "Planning")

        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Publicamos el viernes.",
            startTime: 0,
            endTime: 3,
            isFinal: true)
        try await store.save([speaker])
        _ = try await nextCore(&core)
        try await store.save([segment])
        let transcript = try await nextCore(&core) { $0?.segments.count == 1 }
        XCTAssertEqual(transcript?.speakers.first?.displayName, "Ana")
        XCTAssertEqual(transcript?.segments.first?.text, "Publicamos el viernes.")

        let action = ActionItem(text: "Publicar")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "## Resumen",
            actionItems: [action]))
        let firstSummary = try await nextSummary(&summary) { $0?.draft.actionItems.count == 1 }
        XCTAssertEqual(firstSummary?.version, 1)
        try await store.setActionItem(action.id, done: true)
        let completed = try await nextSummary(&summary) {
            $0?.draft.actionItems.first?.isDone == true
        }
        XCTAssertTrue(completed?.draft.actionItems.first?.isDone == true)

        let card = CompanionCard(
            question: "¿Cuándo?",
            answer: "El viernes.",
            kind: .context,
            source: "meeting",
            askedAt: 1)
        try await store.save([card], for: meeting.id)
        let cards = try await nextCompanion(&companion) { $0.map(\.id) == [card.id] }
        XCTAssertEqual(cards.first?.answer, "El viernes.")
        try await store.deleteCompanionCard(card.id)
        let removedCards = try await nextCompanion(&companion) { $0.isEmpty }
        XCTAssertTrue(removedCards.isEmpty)

        try await store.delete(meeting.id)
        let deletedCore = try await nextCore(&core) { $0 == nil }
        let deletedSummary = try await nextSummary(&summary) { $0 == nil }
        let deletedCards = try await nextCompanion(&companion) { $0.isEmpty }
        XCTAssertNil(deletedCore)
        XCTAssertNil(deletedSummary)
        XCTAssertTrue(deletedCards.isEmpty)

        try await store.restore(meeting.id)
        let restoredCore = try await nextCore(&core) { $0?.segments.count == 1 }
        let restoredSummary = try await nextSummary(&summary) {
            $0?.draft.actionItems.count == 1
        }
        let restoredCards = try await nextCompanion(&companion) { $0.isEmpty }
        XCTAssertEqual(
            restoredCore?.meeting.id,
            meeting.id)
        XCTAssertEqual(restoredSummary?.version, 1)
        XCTAssertTrue(restoredCards.isEmpty)
    }

    func testSummaryObservationSelectsNewestSnapshotAcrossRecipes() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Standup", startedAt: Date())
        try await store.save(meeting)
        var summary = store.observeMeetingReviewSummary(meeting.id).makeAsyncIterator()
        let initialSummary = try await nextSummary(&summary)
        XCTAssertNil(initialSummary)

        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "General",
            actionItems: []))
        _ = try await nextSummary(&summary) { $0?.draft.markdown == "General" }
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.standup.id,
            language: "es",
            markdown: "Standup",
            actionItems: []))

        let newest = try await nextSummary(&summary) {
            $0?.draft.recipeID == Recipe.standup.id
        }
        XCTAssertEqual(newest?.draft.markdown, "Standup")
        XCTAssertEqual(newest?.version, 1)
    }
}

private func nextCore(
    _ iterator: inout AsyncThrowingStream<MeetingStore.MeetingReviewCore?, Error>.Iterator,
    until predicate: (MeetingStore.MeetingReviewCore?) -> Bool = { _ in true }
) async throws -> MeetingStore.MeetingReviewCore? {
    for _ in 0..<12 {
        let value = try await iterator.next()
        if predicate(value ?? nil) { return value ?? nil }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextSummary(
    _ iterator: inout AsyncThrowingStream<(draft: SummaryDraft, version: Int)?, Error>.Iterator,
    until predicate: ((draft: SummaryDraft, version: Int)?) -> Bool = { _ in true }
) async throws -> (draft: SummaryDraft, version: Int)? {
    for _ in 0..<12 {
        let value = try await iterator.next()
        if predicate(value ?? nil) { return value ?? nil }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private func nextCompanion(
    _ iterator: inout AsyncThrowingStream<[CompanionCard], Error>.Iterator,
    until predicate: ([CompanionCard]) -> Bool = { _ in true }
) async throws -> [CompanionCard] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw MeetingDetailObservationTestError.expectedValue
}

private enum MeetingDetailObservationTestError: Error {
    case expectedValue
}
