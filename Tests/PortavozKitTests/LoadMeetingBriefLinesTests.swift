import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class LoadMeetingBriefLinesTests: XCTestCase {
    private let event = UpcomingEvent(
        id: "weekly", title: "Weekly sync", startDate: Date(timeIntervalSince1970: 1_800_000_000), attendees: [])

    func testCachedLinesNeedNoLookup() async throws {
        let library = BriefLinesLibraryFake()
        library.stored = lines(source: MeetingID())
        let useCase = LoadMeetingBriefLines(lines: library, sources: library)

        let loaded = try await useCase(event)

        XCTAssertEqual(loaded, library.stored)
        XCTAssertEqual(library.calls, [.read])
    }

    func testAMissingSourceIsFoundRecordedAndRead() async throws {
        let library = BriefLinesLibraryFake()
        let previous = MeetingID()
        library.previous = previous
        let useCase = LoadMeetingBriefLines(lines: library, sources: library)

        let loaded = try await useCase(event)

        XCTAssertEqual(loaded?.sourceMeetingID, previous)
        XCTAssertEqual(library.calls, [.read, .lookUp("Weekly sync"), .record(previous), .read])
    }

    func testAFirstMeetingRecordsNothing() async throws {
        let library = BriefLinesLibraryFake()
        let first = try await LoadMeetingBriefLines(lines: library, sources: library)(event)
        XCTAssertNil(first)
        XCTAssertEqual(library.calls, [.read, .lookUp("Weekly sync")], "nothing is recorded without a source")
    }

    private func lines(source: MeetingID) -> MeetingBriefLines {
        MeetingBriefLines(
            occurrence: .init(eventID: event.id, startAt: event.startDate),
            sourceMeetingID: source, preparedAt: event.startDate, people: [])
    }
}

private final class BriefLinesLibraryFake: MeetingBriefLinesReading, MeetingBriefSourceRecording,
    @unchecked Sendable {
    enum Call: Equatable {
        case read
        case lookUp(String)
        case record(MeetingID?)
    }

    var stored: MeetingBriefLines?
    var previous: MeetingID?
    var calls: [Call] = []

    func meetingBriefLines(for occurrence: MeetingBriefLines.Occurrence) async throws -> MeetingBriefLines? {
        calls.append(.read)
        return stored
    }

    func previousMeetingBriefOccurrence(title: String, before date: Date) async throws -> MeetingID? {
        calls.append(.lookUp(title))
        return previous
    }

    func recordMeetingBriefSource(eventID: String, eventStartAt: Date, sourceMeetingID: MeetingID?) async throws {
        calls.append(.record(sourceMeetingID))
        stored = sourceMeetingID.map {
            MeetingBriefLines(
                occurrence: .init(eventID: eventID, startAt: eventStartAt),
                sourceMeetingID: $0, preparedAt: eventStartAt, people: [])
        }
    }
}
