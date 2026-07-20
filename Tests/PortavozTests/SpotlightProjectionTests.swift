import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SpotlightProjectionTests: XCTestCase {
    func testProjectionUsesNewestRecipeAndFirstFortyLiveSegmentsInOrder() async throws {
        let store = try MeetingStore.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(title: "Architecture review", startedAt: startedAt)
        try await store.save(meeting)

        let segments = (0..<42).reversed().map { index in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "turn-\(index)",
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                isFinal: true)
        }
        try await store.save(segments)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "General summary",
            actionItems: []))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.standup.id,
            language: "en",
            markdown: "Newest standup summary",
            actionItems: []))

        let documents = try await store.spotlightDocuments()
        let document = try XCTUnwrap(documents.first)

        XCTAssertEqual(document.meetingID, meeting.id)
        XCTAssertEqual(document.title, meeting.title)
        XCTAssertEqual(document.startedAt, startedAt)
        XCTAssertTrue(document.contentDescription.hasPrefix("Newest standup summary\n"))
        XCTAssertTrue(document.contentDescription.contains("turn-0 turn-1 turn-2"))
        XCTAssertTrue(document.contentDescription.hasSuffix("turn-39"))
        XCTAssertFalse(document.contentDescription.contains("turn-40"))
        XCTAssertFalse(document.contentDescription.contains("turn-41"))
    }

    func testProjectionExcludesTombstonesAndCapsDescription() async throws {
        let store = try MeetingStore.inMemory()
        let live = Meeting(title: "Live", startedAt: Date(timeIntervalSince1970: 200))
        let deleted = Meeting(title: "Deleted", startedAt: Date(timeIntervalSince1970: 100))
        try await store.save(live)
        try await store.save(deleted)
        try await store.delete(deleted.id)

        let retained = TranscriptSegment(
            meetingID: live.id,
            channel: .system,
            text: "retained",
            startTime: 1,
            endTime: 2,
            isFinal: true)
        let tombstoned = TranscriptSegment(
            meetingID: live.id,
            channel: .system,
            text: "must-not-index",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        try await store.save([retained, tombstoned])
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE segment SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), tombstoned.id.uuidString])
        }
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: live.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: String(repeating: "a", count: 4_100),
            actionItems: []))

        let documents = try await store.spotlightDocuments()

        XCTAssertEqual(documents.map(\.meetingID), [live.id])
        XCTAssertEqual(documents[0].contentDescription.count, 4_000)
        XCTAssertFalse(documents[0].contentDescription.contains("must-not-index"))
    }

    func testProjectionIsEmptyWithoutLiveMeetings() async throws {
        let store = try MeetingStore.inMemory()

        let documents = try await store.spotlightDocuments()
        XCTAssertTrue(documents.isEmpty)
    }
}
