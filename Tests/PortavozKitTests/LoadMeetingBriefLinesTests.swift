import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class LoadMeetingBriefLinesTests: XCTestCase {
    private let event = UpcomingEvent(
        id: "weekly", title: "Weekly sync", startDate: Date(timeIntervalSince1970: 1_800_000_000), attendees: [])

    func testTheCachedSourceStaysWhileItIsTheLatestOrTheOnlyOne() async throws {
        let source = MeetingID()
        for previous in [source, nil] {
            let library = BriefLinesLibraryFake(stored: lines(source: source), previous: previous)
            let loaded = try await LoadMeetingBriefLines(lines: library, sources: library)(event)
            XCTAssertEqual(loaded?.sourceMeetingID, source)
            let recorded = await library.recorded
            XCTAssertEqual(recorded, [], "nothing is rewritten")
        }
    }

    func testAMissingOrOlderSourceGivesWayToTheLatestSameTitleMeeting() async throws {
        let latest = MeetingID()
        for stored in [nil, lines(source: MeetingID())] {
            let library = BriefLinesLibraryFake(stored: stored, previous: latest)
            let loaded = try await LoadMeetingBriefLines(lines: library, sources: library)(event)
            XCTAssertEqual(loaded?.sourceMeetingID, latest)
            let recorded = await library.recorded
            XCTAssertEqual(recorded, [latest])
        }
    }

    func testAFirstMeetingRecordsNothing() async throws {
        let library = BriefLinesLibraryFake(stored: nil, previous: nil)
        let loaded = try await LoadMeetingBriefLines(lines: library, sources: library)(event)
        XCTAssertNil(loaded)
        let recorded = await library.recorded
        XCTAssertEqual(recorded, [])
        let lookups = await library.lookups
        XCTAssertEqual(lookups, [event.id], "the event's identifier leads the lookup")
    }

    private func lines(source: MeetingID) -> MeetingBriefLines {
        MeetingBriefLines(
            occurrence: .init(event: event), sourceMeetingID: source, preparedAt: event.startDate, people: [])
    }
}

private actor BriefLinesLibraryFake: MeetingBriefLinesReading, MeetingBriefSourceRecording {
    private var stored: MeetingBriefLines?
    private let previous: MeetingID?
    private(set) var lookups: [String] = []
    private(set) var recorded: [MeetingID?] = []

    init(stored: MeetingBriefLines?, previous: MeetingID?) {
        self.stored = stored
        self.previous = previous
    }

    func meetingBriefLines(for occurrence: MeetingBriefLines.Occurrence) async throws -> MeetingBriefLines? {
        stored
    }

    func previousMeetingBriefOccurrence(eventID: String, title: String, before date: Date) async throws -> MeetingID? {
        lookups.append(eventID)
        return previous
    }

    func recordMeetingBriefSource(eventID: String, eventStartAt: Date, sourceMeetingID: MeetingID?) async throws {
        recorded.append(sourceMeetingID)
        stored = sourceMeetingID.map {
            MeetingBriefLines(
                occurrence: .init(eventID: eventID, startAt: eventStartAt),
                sourceMeetingID: $0, preparedAt: eventStartAt, people: [])
        }
    }
}
