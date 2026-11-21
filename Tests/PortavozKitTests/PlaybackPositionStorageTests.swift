import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

final class PlaybackPositionStorageTests: XCTestCase {
    private var store: MeetingStore!

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    private func seedMeeting(_ title: String = "Weekly sync") async throws -> Meeting {
        let meeting = Meeting(title: title, startedAt: Date())
        try await store.save(meeting)
        return meeting
    }

    private func position(
        _ meeting: Meeting, _ seconds: TimeInterval, heard: Bool = false, at offset: TimeInterval
    ) -> MeetingPlaybackPosition {
        MeetingPlaybackPosition(
            meetingID: meeting.id, seconds: seconds, isHeard: heard,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset))
    }

    func testBatchedReadReturnsOnlyMeetingsThatWerePlayed() async throws {
        let first = try await seedMeeting()
        let second = try await seedMeeting("Retro")
        let unheard = try await seedMeeting("Planning")
        try await store.savePlaybackPosition(position(first, 1_880, at: 0))
        try await store.savePlaybackPosition(position(second, 0, heard: true, at: 0))

        let positions = try await store.playbackPositions(for: [first.id, second.id, unheard.id, first.id])

        XCTAssertEqual(Set(positions.keys), [first.id, second.id])
        XCTAssertEqual(positions[first.id]?.seconds, 1_880)
        XCTAssertEqual(positions[first.id]?.isHeard, false)
        XCTAssertEqual(positions[second.id]?.isHeard, true)
        XCTAssertNil(positions[unheard.id], "a meeting never played reads as unheard")
        let none = try await store.playbackPositions(for: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testLaterPositionReplacesAndOlderOneIsIgnored() async throws {
        let meeting = try await seedMeeting()
        try await store.savePlaybackPosition(position(meeting, 40, at: 10))
        try await store.savePlaybackPosition(position(meeting, 95, at: 20))
        try await store.savePlaybackPosition(position(meeting, 12, at: 15))

        let saved = try await store.playbackPositions(for: [meeting.id])[meeting.id]
        XCTAssertEqual(saved?.seconds, 95, "a checkpoint that lands late must not rewind the position")
        XCTAssertEqual(saved?.updatedAt, Date(timeIntervalSince1970: 1_800_000_020))
    }

    func testHeardStaysHeardAfterListeningAgain() async throws {
        let meeting = try await seedMeeting()
        try await store.savePlaybackPosition(position(meeting, 0, heard: true, at: 0))
        try await store.savePlaybackPosition(position(meeting, 300, at: 5))

        let saved = try await store.playbackPositions(for: [meeting.id])[meeting.id]
        XCTAssertEqual(saved?.seconds, 300)
        XCTAssertEqual(saved?.isHeard, true)
    }

    func testTrashHidesThePositionAndRestoreBringsItBack() async throws {
        let meeting = try await seedMeeting()
        try await store.savePlaybackPosition(position(meeting, 61, at: 0))

        try await store.delete(meeting.id)
        let trashed = try await store.playbackPositions(for: [meeting.id])
        XCTAssertTrue(trashed.isEmpty)

        try await store.restore(meeting.id)
        let restored = try await store.playbackPositions(for: [meeting.id])
        XCTAssertEqual(restored[meeting.id]?.seconds, 61)
    }

    func testPurgingAMeetingDeletesItsPosition() async throws {
        let meeting = try await seedMeeting()
        try await store.savePlaybackPosition(position(meeting, 61, at: 0))
        try await store.delete(meeting.id)
        try await store.purge(meeting.id)

        let count = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingPlaybackPosition")
        }
        XCTAssertEqual(count, 0)
    }

    func testSchemaRejectsNegativePositions() async throws {
        let meeting = try await seedMeeting()
        do {
            try await store.database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO meetingPlaybackPosition (meetingID, positionSeconds, updatedAt)
                        VALUES (?, -1, ?)
                        """,
                    arguments: [meeting.id.rawValue.uuidString, Date()])
            }
            XCTFail("a negative position must violate the schema")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func testResumeTimeSkipsBothEnds() {
        let id = MeetingID()
        func resume(_ seconds: TimeInterval) -> TimeInterval? {
            MeetingPlaybackPosition(meetingID: id, seconds: seconds, isHeard: false, updatedAt: Date())
                .resumeTime(duration: 60)
        }
        XCTAssertNil(resume(0))
        XCTAssertNil(resume(0.5))
        XCTAssertEqual(resume(30), 30)
        XCTAssertNil(resume(59.5), "the last second opens at the start instead of at the end")
        XCTAssertNil(resume(90), "a position past a trimmed end opens at the start")
        XCTAssertEqual(
            MeetingPlaybackPosition(meetingID: id, seconds: -.infinity, isHeard: false, updatedAt: Date()).seconds,
            0)
    }
}
