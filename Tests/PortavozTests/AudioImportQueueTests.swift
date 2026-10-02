import Foundation
import PortavozCore
import StorageKit
import XCTest

final class AudioImportQueueTests: XCTestCase, @unchecked Sendable {
    func testPagedProjectionIncludesEveryImportOnceAndExcludesDeletedRows() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        var ids: Set<MeetingID> = []
        for _ in 0..<23 { ids.insert(try await fixture.admit().meetingID) }
        let first = try await fixture.store.audioImportQueuePage()
        let last = try await fixture.store.audioImportQueuePage(offset: 20)
        XCTAssertEqual(first.entries.count, 20)
        XCTAssertEqual(last.entries.count, 3)
        XCTAssertEqual(first.total, 23)
        XCTAssertEqual(first.unfinished, 23)
        XCTAssertTrue(first.hasNext)
        XCTAssertFalse(last.hasNext)
        XCTAssertEqual(Set((first.entries + last.entries).map(\.id)), ids)
        let id = try XCTUnwrap(first.entries.first).id
        try await fixture.store.delete(id)
        let current = try await fixture.store.audioImportQueuePage(limit: 50)
        XCTAssertEqual(current.total, 22)
        XCTAssertFalse(current.entries.contains { $0.id == id })
    }

    func testTerminalRowsMoveBehindPendingAndRetryRejoinsWithoutDuplicates() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let first = try await fixture.admit()
        let second = try await fixture.admit()
        try await fixture.store.cancelAudioImport(for: second.meetingID)
        let cancelled = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(cancelled.entries.map(\.id), [first.meetingID, second.meetingID])
        XCTAssertEqual(cancelled.unfinished, 1)
        try await fixture.store.retryAudioImport(for: second.meetingID)
        let retry = try await fixture.store.audioImportQueuePage()
        XCTAssertEqual(retry.total, 2)
        XCTAssertEqual(retry.unfinished, 2)
    }

    func testEmptyBoundaryAndInvalidPagesAreExplicit() async throws {
        let fixture = try ImportQueueFixture()
        defer { fixture.remove() }
        let empty = try await fixture.store.audioImportQueuePage(offset: 20)
        XCTAssertEqual(empty.total, 0)
        XCTAssertFalse(empty.hasNext)
        for (offset, limit) in [(-1, 20), (0, 0), (0, 51)] {
            do {
                _ = try await fixture.store.audioImportQueuePage(offset: offset, limit: limit)
                XCTFail("Invalid pages must reject, not silently truncate or scan the queue")
            } catch {}
        }
    }
}
