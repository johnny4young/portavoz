import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class MeetingLibraryQueryTests: XCTestCase {
    func testInvalidInputsReturnEmptyWithoutReadingStorage() async throws {
        let reader = MeetingLibraryQueryReaderSpy()
        let query = QueryMeetingLibrary(reader: reader)

        let noMeetings = try await query.meetings(limit: 0)
        let noSearch = try await query.search("  \n ", limit: 20)
        let noSearchLimit = try await query.search("budget", limit: -1)
        let noItems = try await query.openItems(limit: 0)

        XCTAssertTrue(noMeetings.isEmpty)
        XCTAssertTrue(noSearch.isEmpty)
        XCTAssertTrue(noSearchLimit.isEmpty)
        XCTAssertTrue(noItems.isEmpty)
        let calls = await reader.calls
        XCTAssertEqual(calls, [])
    }

    func testValidInputsAreNormalizedAndForwardTheirBounds() async throws {
        let reader = MeetingLibraryQueryReaderSpy()
        let query = QueryMeetingLibrary(reader: reader)

        _ = try await query.meetings(limit: 7)
        _ = try await query.search("  presupuesto \n", limit: 3)
        _ = try await query.openItems(limit: 9)

        let calls = await reader.calls
        XCTAssertEqual(calls, [
            .meetings(7),
            .search("presupuesto", 3),
            .openItems(9),
        ])
    }
}

private actor MeetingLibraryQueryReaderSpy: MeetingLibraryQueryReading {
    enum Call: Equatable {
        case meetings(Int?)
        case detail(MeetingID)
        case search(String, Int)
        case openItems(Int)
    }

    private(set) var calls: [Call] = []

    func meetingLibraryMeetings(limit: Int?) async throws -> [Meeting] {
        calls.append(.meetings(limit))
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) async throws -> MeetingLibraryDetail? {
        calls.append(.detail(id))
        return nil
    }

    func meetingLibrarySearch(
        _ query: String,
        limit: Int
    ) async throws -> [LibrarySearchHit] {
        calls.append(.search(query, limit))
        return []
    }

    func meetingLibraryOpenItems(limit: Int) async throws -> [LibraryOpenItem] {
        calls.append(.openItems(limit))
        return []
    }
}
