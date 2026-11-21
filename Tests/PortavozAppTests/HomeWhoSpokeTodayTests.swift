import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class HomeWhoSpokeTodayTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_789_000_000)
    private var day: DateInterval { DateInterval(start: dayStart, duration: 24 * 3600) }

    private func at(_ hour: Double) -> Date { dayStart.addingTimeInterval(hour * 3600) }

    private func row(_ title: String, from start: Double, to end: Double, voices: [MeetingVoiceColumns.Voice])
        -> MeetingStore.LibraryMeetingRow {
        MeetingStore.LibraryMeetingRow(
            meeting: Meeting(title: title, startedAt: at(start), endedAt: at(end)),
            voiceColumns: MeetingVoiceColumns(
                duration: (end - start) * 3600, columns: Array(0..<UInt8(voices.count)), voices: voices))
    }

    private func voice(_ name: String?, isMe: Bool = false, talk: TimeInterval) -> MeetingVoiceColumns.Voice {
        MeetingVoiceColumns.Voice(
            speakerID: SpeakerID(), isMe: isMe, label: "S1", displayName: name, personID: nil,
            talkSeconds: talk, firstHeard: 0)
    }

    private func today(events: [UpcomingEvent] = []) -> TodayVoices {
        TodayVoices(
            day: day, now: at(15),
            meetings: [
                row("Sprint demo", from: 10, to: 10.7, voices: [
                    voice(nil, isMe: true, talk: 600), voice("Marta", talk: 1_200), voice(nil, talk: 90)
                ]),
                row("Retro", from: 13, to: 14.06, voices: [voice(nil, isMe: true, talk: 900), voice("Marta", talk: 300)])
            ],
            events: events, people: [:])
    }

    func testSummaryCountsRecordedMeetingsTheirLengthAndWhatIsLeft() {
        let event = UpcomingEvent(
            id: "sync", title: "Sync", startDate: at(16), attendees: [], endDate: at(16.5))
        XCTAssertEqual(
            HomeWhoSpokeToday.summary(today(events: [event])), "2 meetings recorded · 1 h 46 min · 1 to go")
        XCTAssertEqual(HomeWhoSpokeToday.summary(today()), "2 meetings recorded · 1 h 46 min")
        let empty = TodayVoices(day: day, now: at(15), meetings: [], events: [event], people: [:])
        XCTAssertEqual(HomeWhoSpokeToday.summary(empty), "1 to go", "nothing recorded keeps only what is ahead")
        XCTAssertTrue(HomeWhoSpokeToday.isShown(empty))
        XCTAssertFalse(HomeWhoSpokeToday.isShown(
            TodayVoices(day: day, now: at(15), meetings: [], events: [], people: [:])))
    }

    func testColumnsNameWhereEachVoiceSpokeAndMeasureAgainstTheLongest() throws {
        let talkers = today().talkers
        XCTAssertEqual(talkers.map(HomeTalkerColumn.name), ["You", "Marta", "S1"])
        XCTAssertEqual(
            talkers.map(HomeTalkerColumn.caption), ["2 meetings", "2 meetings", "not named yet"],
            "an unnamed voice asks to be named before it says where it spoke")
        let longest = try XCTUnwrap(talkers.map(\.talkSeconds).max())
        let fills = talkers.map { Double(HomeTalkerColumn.fill($0, longest: longest)) }
        XCTAssertEqual(fills[0], 1)
        XCTAssertEqual(fills[1], 1)
        XCTAssertEqual(fills[2], 0.06, accuracy: 0.0001)
        XCTAssertEqual(HomeTalkerColumn.fill(talkers[0], longest: 0), 0)

        let single = TodayVoices(
            day: day, now: at(15),
            meetings: [row("2026-11-21 Retro", from: 13, to: 14, voices: [voice("Nora", talk: 60)])],
            events: [], people: [:])
        XCTAssertEqual(single.talkers.map(HomeTalkerColumn.caption), ["Retro"], "one meeting is named by its title")
    }
}
