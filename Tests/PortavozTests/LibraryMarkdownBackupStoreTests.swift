import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class LibraryMarkdownBackupStoreTests: XCTestCase {
    func testSnapshotIsLiveOrderedReadConsistentAndIsolatesCorruptAggregate() async throws {
        let store = try MeetingStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let older = Meeting(title: "Older", startedAt: base)
        let newer = Meeting(
            title: "Newer",
            startedAt: base.addingTimeInterval(60))
        let corrupt = Meeting(
            title: "Corrupt",
            startedAt: base.addingTimeInterval(120))
        let deleted = Meeting(
            title: "Deleted",
            startedAt: base.addingTimeInterval(180))
        for meeting in [older, newer, corrupt, deleted] {
            try await store.save(meeting)
        }

        let speaker = Speaker(
            meetingID: newer.id,
            label: "S1",
            displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: newer.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Budget approved",
            startTime: 1,
            endTime: 2)
        try await store.save([speaker])
        try await store.save([segment])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: newer.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## General",
            actionItems: [ActionItem(text: "Ship")]))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: newer.id,
            recipeID: Recipe.standup.id,
            language: "en",
            markdown: "## Standup",
            actionItems: []))

        let corruptSegment = TranscriptSegment(
            meetingID: corrupt.id,
            channel: .system,
            text: "Unreadable channel",
            startTime: 0,
            endTime: 1)
        try await store.save([corruptSegment])
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE segment SET channel = 'invalid' WHERE id = ?",
                arguments: [corruptSegment.id.uuidString])
        }
        try await store.delete(deleted.id)

        let snapshot = try await store.libraryMarkdownBackupSnapshots()

        XCTAssertEqual(snapshot.meetings.map(\.meeting.id), [newer.id, older.id])
        let newerSnapshot = try XCTUnwrap(snapshot.meetings.first)
        XCTAssertEqual(newerSnapshot.speakers.map(\.displayName), ["Ana"])
        XCTAssertEqual(newerSnapshot.segments.map(\.text), ["Budget approved"])
        XCTAssertEqual(newerSnapshot.summary?.markdown, "## General")
        XCTAssertEqual(newerSnapshot.summary?.actionItems.map(\.text), ["Ship"])
        XCTAssertEqual(newerSnapshot.summaryVersion, 1)
        XCTAssertEqual(snapshot.failures, [MeetingMarkdownBackupReadFailure(
            meetingID: corrupt.id,
            title: "Corrupt")])
    }
}
