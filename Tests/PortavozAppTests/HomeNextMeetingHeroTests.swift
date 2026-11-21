import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class HomeNextMeetingHeroTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let posix = Locale(identifier: "en_US_POSIX")

    func testCountsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-(44 * 60 + 38)), locale: posix),
            .counting(lead: "44", trail: ":38", unit: .minutes))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-0.2), locale: posix),
            .counting(lead: "00", trail: ":01", unit: .minutes),
            "a partial second still counts until the start")
    }

    func testCountsWholeMinutesPastAnHour() {
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_600), locale: posix),
            .counting(lead: "60", trail: ":00", unit: .minutes))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_600.5), locale: posix),
            .counting(lead: "1", trail: ":00", unit: .hours))
        XCTAssertEqual(
            NextMeetingCountdown(start: start, at: start.addingTimeInterval(-3_720), locale: posix),
            .counting(lead: "1", trail: ":01", unit: .hours),
            "a tick on the minute shows the minute that follows it")
        XCTAssertEqual(
            NextMeetingCountdown(
                start: start, at: start.addingTimeInterval(-(2 * 3_600 + 15 * 60 + 59)), locale: posix),
            .counting(lead: "2", trail: ":15", unit: .hours))
    }

    func testScheduleTicksPerMinuteThenPerSecondAndStopsAtTheStart() {
        var entries = CountdownSchedule(start: start)
            .entries(from: start.addingTimeInterval(-3_725.5), mode: .normal)
        let offsets = (0..<4).compactMap { _ in entries.next() }
            .map { start.timeIntervalSince($0) }
        XCTAssertEqual(offsets, [3_725.5, 3_720, 3_660, 3_600])
        XCTAssertEqual(entries.next().map { start.timeIntervalSince($0) }, 3_599)

        var last = CountdownSchedule(start: start)
            .entries(from: start.addingTimeInterval(-1.5), mode: .normal)
        XCTAssertEqual(
            [last.next(), last.next(), last.next()].compactMap { $0 }.map { start.timeIntervalSince($0) },
            [1.5, 1, 0])
        XCTAssertNil(last.next(), "nothing ticks once the meeting has started")
    }

    func testSwitchesToNowAtTheStart() {
        XCTAssertEqual(NextMeetingCountdown(start: start, at: start), .now)
        XCTAssertEqual(NextMeetingCountdown(start: start, at: start.addingTimeInterval(600)), .now)
    }

    func testInviteesKeepCalendarOrderWithYouLast() {
        let cast = HomeNextMeetingHero.inviteeCast(["Marta", "Ilarion"])
        XCTAssertEqual(cast.voices.map(\.name), ["Marta", "Ilarion", nil])
        XCTAssertEqual(cast.voices.last?.tint, .you)
        XCTAssertEqual(
            cast.voices.first?.tint, .hue(VoiceHue.index(name: "Marta")),
            "an invitee wears the hue their name has in recorded meetings")
    }

    func testInviteesPastTheCastFoldIntoOthers() {
        let names = (1...7).map { "Person \($0)" }
        let cast = HomeNextMeetingHero.inviteeCast(names)
        XCTAssertEqual(cast.voices.count, VoiceHue.paletteSize + 1)
        XCTAssertEqual(cast.others.map(\.name), ["Person 6", "Person 7"])
    }

    func testFactsKeepOnlyWhatTheCalendarGave() {
        let full = UpcomingEvent(
            id: "e", title: "Sync", startDate: start, attendees: [],
            endDate: start.addingTimeInterval(45 * 60), platform: .googleMeet, recurrence: .weekly)
        XCTAssertEqual(
            HomeNextMeetingHero.facts(full),
            ["Google Meet", L10n.format("%d min", 45), L10n.text("weekly")].joined(separator: " · "))

        let bare = UpcomingEvent(id: "e", title: "Sync", startDate: start, attendees: [])
        XCTAssertNil(HomeNextMeetingHero.facts(bare))
    }
}
