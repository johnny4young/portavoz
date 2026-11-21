import Foundation
import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

final class TodayVoicesStorageTests: XCTestCase {
    private var store: MeetingStore!
    private let dayStart = Date(timeIntervalSince1970: 1_789_000_000)
    private var day: DateInterval { DateInterval(start: dayStart, duration: 24 * 3600) }

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    @discardableResult
    private func seed(
        _ title: String, at hour: Double, state: MeetingLifecycleState = .ready, speaker name: String? = "Marta"
    ) async throws -> (meeting: Meeting, speaker: Speaker) {
        let start = dayStart.addingTimeInterval(hour * 3600)
        let meeting = Meeting(
            title: title, startedAt: start,
            endedAt: state == .recording ? nil : start.addingTimeInterval(600), lifecycleState: state)
        try await store.save(meeting)
        let speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: name)
        try await store.save([speaker])
        try await store.save([TranscriptSegment(
            meetingID: meeting.id, speakerID: speaker.id, channel: .system,
            text: "hola", startTime: 0, endTime: 30, isFinal: true)])
        return (meeting, speaker)
    }

    private func storedStrips() async throws -> Int {
        try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetingVoiceColumns") ?? 0
        }
    }

    func testMeetingRowsReadOnlyLiveMeetingsStartedInsideTheDayEarliestFirst() async throws {
        try await seed("Yesterday", at: -1)
        try await seed("Afternoon", at: 14)
        try await seed("Morning", at: 9)
        try await seed("Tomorrow", at: 24)
        let deleted = try await seed("Deleted", at: 11)
        try await store.delete(deleted.meeting.id)

        let rows = try await store.meetingRows(startedIn: day)

        XCTAssertEqual(rows.map(\.meeting.title), ["Morning", "Afternoon"])
        XCTAssertEqual(rows.map { $0.voiceColumns?.voices.map(\.talkSeconds) }, [[30], [30]])
        let stored = try await storedStrips()
        XCTAssertEqual(stored, 2, "finished meetings store their missing strip")
    }

    func testARecordingStartedBeforeMidnightStillShows() async throws {
        try await seed("Late call", at: -0.5, state: .recording)
        try await seed("Finished late", at: -0.4)

        let rows = try await store.meetingRows(startedIn: day)

        XCTAssertEqual(rows.map(\.meeting.title), ["Late call"])
    }

    func testARecordingIsBinnedWithoutStoringItsStrip() async throws {
        try await seed("Live", at: 15, state: .recording)

        let rows = try await store.meetingRows(startedIn: day)

        XCTAssertEqual(rows.first?.voiceColumns?.voices.map(\.displayName), ["Marta"])
        let stored = try await storedStrips()
        XCTAssertEqual(stored, 0)
    }

    func testVoicesCarryTheirLivePerson() async throws {
        let finished = try await seed("Finished", at: 9)
        let live = try await seed("Live", at: 15, state: .recording)
        let link = try await store.createPersonAndLink(
            speakerID: finished.speaker.id, preferredName: "Marta", source: .manualName)
        _ = try await store.linkSpeaker(
            live.speaker.id, to: link.person.id, observedAlias: "Marta", source: .manualName)

        var rows = try await store.meetingRows(startedIn: day)
        XCTAssertEqual(rows.map { $0.voiceColumns?.voices.first?.personID }, [link.person.id, link.person.id])

        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE person SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), link.person.id.rawValue.uuidString])
        }
        rows = try await store.meetingRows(startedIn: day)
        XCTAssertEqual(
            rows.map { $0.voiceColumns?.voices.first?.personID }, [nil, nil], "a removed person no longer groups")
    }

    func testPeopleMatchingAliasesKeepsAmbiguityPerNameAsGiven() async throws {
        let first = try await seed("A", at: 9, speaker: "Ana")
        let second = try await seed("B", at: 10, speaker: "Ana")
        let third = try await seed("C", at: 11, speaker: "Marta")
        let anaOne = try await store.createPersonAndLink(
            speakerID: first.speaker.id, preferredName: "Ana", source: .manualName)
        let anaTwo = try await store.createPersonAndLink(
            speakerID: second.speaker.id, preferredName: "Ana", source: .manualName)
        let marta = try await store.createPersonAndLink(
            speakerID: third.speaker.id, preferredName: "Marta", source: .manualName)

        let matches = try await store.people(matchingAliases: ["Ana", "  MÁRTA ", "Marta", "Nobody", " "])

        XCTAssertEqual(Set(matches.keys), ["Ana", "  MÁRTA ", "Marta"])
        XCTAssertEqual(Set(matches["Ana"]?.map(\.id) ?? []), [anaOne.person.id, anaTwo.person.id])
        XCTAssertEqual(matches["  MÁRTA "]?.map(\.id), [marta.person.id])
        XCTAssertEqual(matches["Marta"]?.map(\.id), [marta.person.id])
        let repeated = try await store.people(matchingAliases: ["Marta", "Marta"])
        XCTAssertEqual(repeated["Marta"]?.map(\.id), [marta.person.id], "a repeated name is not ambiguity")
        let none = try await store.people(matchingAliases: [])
        XCTAssertTrue(none.isEmpty)
    }
}
