import Foundation
import PortavozCore
import StorageKit
import XCTest

final class PresentationReadStorageTests: XCTestCase {
    func testLiveMeetingCountExcludesDeletedRoots() async throws {
        let store = try MeetingStore.inMemory()
        let live = Meeting(title: "Live", startedAt: Date())
        let deleted = Meeting(
            title: "Deleted",
            startedAt: Date().addingTimeInterval(1))
        try await store.save(live)
        try await store.save(deleted)
        let initialCount = try await store.liveMeetingCount()
        XCTAssertEqual(initialCount, 2)

        try await store.delete(deleted.id)

        let remainingCount = try await store.liveMeetingCount()
        XCTAssertEqual(remainingCount, 1)
    }

    func testMeetingBriefSummaryProjectionIsBatchedLatestAndLive() async throws {
        let store = try MeetingStore.inMemory()
        let first = Meeting(title: "Budget", startedAt: Date())
        let second = Meeting(
            title: "Rollout",
            startedAt: Date().addingTimeInterval(1))
        let deleted = Meeting(
            title: "Deleted",
            startedAt: Date().addingTimeInterval(2))
        for meeting in [first, second, deleted] {
            try await store.save(meeting)
        }
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: first.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Old budget",
            actionItems: []))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: first.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Current budget",
            actionItems: []))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: second.id,
            recipeID: Recipe.standup.id,
            language: "en",
            markdown: "Different recipe",
            actionItems: []))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: deleted.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Deleted budget",
            actionItems: []))
        try await store.delete(deleted.id)

        let projection = try await store.meetingBriefSummaryMarkdowns(
            for: [first.id, second.id, deleted.id, first.id])

        XCTAssertEqual(projection, [first.id: "Current budget"])
    }
}
