import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class MenuBarObservationTests: XCTestCase {
    func testRecentMeetingObservationStaysBoundedOrderedAndLiveRooted() async throws {
        let store = try MeetingStore.inMemory()
        var recents = store.observeMenuBarMeetings(limit: 3).makeAsyncIterator()
        let initial = try await nextMenuBarMeetings(&recents)
        XCTAssertTrue(initial.isEmpty)

        let base = Date(timeIntervalSince1970: 1_789_000_000)
        let meetings = (0..<4).map { offset in
            Meeting(
                title: "Meeting \(offset)",
                startedAt: base.addingTimeInterval(Double(offset)))
        }
        for meeting in meetings {
            try await store.save(meeting)
        }

        let newest = try await nextMenuBarMeetings(&recents) {
            $0.map(\.meeting.id) == [meetings[3].id, meetings[2].id, meetings[1].id]
        }
        XCTAssertEqual(newest.map(\.meeting.title), ["Meeting 3", "Meeting 2", "Meeting 1"])

        try await store.delete(meetings[3].id)
        let afterDelete = try await nextMenuBarMeetings(&recents) {
            $0.map(\.meeting.id) == [meetings[2].id, meetings[1].id, meetings[0].id]
        }
        XCTAssertEqual(afterDelete.count, 3)

        try await store.restore(meetings[3].id)
        let restored = try await nextMenuBarMeetings(&recents) {
            $0.first?.meeting.id == meetings[3].id
        }
        XCTAssertEqual(restored.map(\.meeting.id), [meetings[3].id, meetings[2].id, meetings[1].id])
    }

    func testTheRecordingStaysOutAndFinishedMeetingsCarryTheirStrips() async throws {
        let store = try MeetingStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        let finished = Meeting(title: "Finished", startedAt: base)
        let live = Meeting(title: "Live", startedAt: base.addingTimeInterval(60), lifecycleState: .recording)
        try await store.save(finished)
        try await store.save(live)
        let me = Speaker(meetingID: finished.id, label: "Me", isMe: true)
        try await store.save([me])
        try await store.save([TranscriptSegment(
            meetingID: finished.id, speakerID: me.id, channel: .microphone,
            text: "hola", startTime: 0, endTime: 5, isFinal: true)])
        var recents = store.observeMenuBarMeetings(limit: 3).makeAsyncIterator()

        let next = try await recents.next()
        let first = try XCTUnwrap(next)
        XCTAssertEqual(first.rows.map(\.meeting.id), [finished.id], "the panel draws the recording live")
        XCTAssertEqual(first.uncachedVoiceColumns, [finished.id], "the observation only reads the cache")
        _ = try await store.voiceColumns(for: first.uncachedVoiceColumns)
        try await store.save(Meeting(title: "Next", startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let rows = try await nextMenuBarMeetings(&recents) { $0.first?.voiceColumns != nil }
        XCTAssertEqual(rows.first?.voiceColumns?.voices.first?.isMe, true)
    }
}

private func nextMenuBarMeetings(
    _ iterator: inout AsyncThrowingStream<MeetingStore.LibraryMeetingRows, Error>.Iterator,
    until predicate: ([MeetingStore.LibraryMeetingRow]) -> Bool = { _ in true }
) async throws -> [MeetingStore.LibraryMeetingRow] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate).rows
        if predicate(value) { return value }
    }
    throw MenuBarObservationTestError.expectedValue
}

private enum MenuBarObservationTestError: Error {
    case expectedValue
}
