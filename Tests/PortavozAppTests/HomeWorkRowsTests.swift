import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class HomeWorkRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let me = OpenItemSource.Voice(speakerID: SpeakerID(), isMe: true, label: "Me", displayName: nil)
    private let marta = OpenItemSource.Voice(speakerID: SpeakerID(), isMe: false, label: "S1", displayName: "Marta")
    private let unnamed = OpenItemSource.Voice(speakerID: SpeakerID(), isMe: false, label: "S3", displayName: nil)

    func testWhoSaidItNamesTheSpeakerAndWhetherTheOwnerSpokeIt() {
        XCTAssertEqual(HomeYoursToDo.whoSaid(me, ownerSaidIt: true), L10n.text("You said it"))
        XCTAssertEqual(HomeYoursToDo.whoSaid(me, ownerSaidIt: false), L10n.text("You asked"))
        XCTAssertEqual(HomeYoursToDo.whoSaid(marta, ownerSaidIt: true), L10n.format("%@ said it", "Marta"))
        XCTAssertEqual(HomeYoursToDo.whoSaid(unnamed, ownerSaidIt: false), L10n.format("%@ asked", "S3"))
        let source = OpenItemSource(saidBy: marta, time: 10, owner: me, dueAt: nil)
        XCTAssertFalse(source.ownerSaidIt)
    }

    func testWhereSaidPairsTheMeetingWithTheMoment() {
        let open = LibraryOpenItem(
            meetingID: MeetingID(), meetingTitle: "2026-07-10 Sprint Demo · Zephyr", item: ActionItem(text: "Ship"))
        XCTAssertEqual(HomeYoursToDo.whereSaid(open, time: 138, led: true), "· Sprint Demo · Zephyr · 02:18")
        XCTAssertEqual(HomeYoursToDo.whereSaid(open, time: nil, led: false), "Sprint Demo · Zephyr")
    }

    func testTheOwnerChipAddsTheDueWeekday() {
        XCTAssertEqual(HomeYoursToDo.ownerChip(marta, due: nil), "Marta")
        let chip = HomeYoursToDo.ownerChip(me, due: now, now: now, calendar: calendar)
        XCTAssertEqual(chip, "\(L10n.text("You")) · \(now.formatted(Meeting.weekdayStyle))")
        let later = now.addingTimeInterval(20 * 86_400)
        XCTAssertEqual(
            HomeYoursToDo.ownerChip(marta, due: later, now: now, calendar: calendar),
            "Marta · \(later.formatted(Meeting.dayStyle))", "a due day weeks away names its date")
        let overdue = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(
            HomeYoursToDo.ownerChip(marta, due: overdue, now: now, calendar: calendar),
            "Marta · \(overdue.formatted(Meeting.dayStyle))", "a past due day never reads as the coming weekday")
    }

    func testTheRadarLinkPrefersSuggestionsToReview() {
        XCTAssertEqual(HomeYoursToDo.radarLink(suggestions: 4, hidden: 2), L10n.format("%d suggestions to review in Radar", 4))
        XCTAssertEqual(HomeYoursToDo.radarLink(suggestions: 1, hidden: 0), L10n.text("1 suggestion to review in Radar"))
        XCTAssertEqual(HomeYoursToDo.radarLink(suggestions: 0, hidden: 2), L10n.format("%d more in Radar", 2))
        XCTAssertNil(HomeYoursToDo.radarLink(suggestions: 0, hidden: 0))
    }

    func testPickUpRowsSayWhereListeningStopped() {
        XCTAssertEqual(HomePickUp.progressText(.stopped(at: 1_880)), L10n.format("stopped at %@", "31:20"))
        XCTAssertEqual(HomePickUp.progressText(.unheard), L10n.text("unheard"))
        XCTAssertNotNil(HomePickUp.stoppedHelp(.stopped(at: 10)))
        XCTAssertNil(HomePickUp.stoppedHelp(.unheard), "an unheard row never claims you stopped")
    }

    func testPickUpFactsUseTheWeekdayWithinAWeek() {
        let recent = Meeting(
            title: "Planning", startedAt: now.addingTimeInterval(-2 * 86_400),
            endedAt: now.addingTimeInterval(-2 * 86_400 + 38 * 60))
        let older = Meeting(
            title: "Retro", startedAt: now.addingTimeInterval(-20 * 86_400),
            endedAt: now.addingTimeInterval(-20 * 86_400 + 40 * 60))
        let minutes = L10n.format("%d min", 38)
        let recentFacts = recent.recentDayAndLength(now: now, calendar: calendar)
        XCTAssertTrue(recentFacts.hasSuffix(" · \(minutes)"), recentFacts)
        XCTAssertLessThan(recentFacts.count, older.dayAndLength.count, "a recent meeting names only its weekday")
        XCTAssertEqual(older.recentDayAndLength(now: now, calendar: calendar), older.dayAndLength)
    }
}
