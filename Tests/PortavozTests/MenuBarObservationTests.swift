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
            $0.map(\.id) == [meetings[3].id, meetings[2].id, meetings[1].id]
        }
        XCTAssertEqual(newest.map(\.title), ["Meeting 3", "Meeting 2", "Meeting 1"])

        try await store.delete(meetings[3].id)
        let afterDelete = try await nextMenuBarMeetings(&recents) {
            $0.map(\.id) == [meetings[2].id, meetings[1].id, meetings[0].id]
        }
        XCTAssertEqual(afterDelete.count, 3)

        try await store.restore(meetings[3].id)
        let restored = try await nextMenuBarMeetings(&recents) {
            $0.first?.id == meetings[3].id
        }
        XCTAssertEqual(restored.map(\.id), [meetings[3].id, meetings[2].id, meetings[1].id])
    }
}

private func nextMenuBarMeetings(
    _ iterator: inout AsyncThrowingStream<[Meeting], Error>.Iterator,
    until predicate: ([Meeting]) -> Bool = { _ in true }
) async throws -> [Meeting] {
    for _ in 0..<12 {
        let candidate = try await iterator.next()
        let value = try XCTUnwrap(candidate)
        if predicate(value) { return value }
    }
    throw MenuBarObservationTestError.expectedValue
}

private enum MenuBarObservationTestError: Error {
    case expectedValue
}
