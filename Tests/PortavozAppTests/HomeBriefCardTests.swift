import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class HomeBriefCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testMetaPairsTheTimeWithWhatIsStillPending() {
        let quote = line(.quote, .said, segment: UUID(), time: 760)
        let question = line(.question, .unresolved, segment: UUID(), time: 760)
        let unanchored = line(.commitment, .closed, segment: nil, time: 0)

        XCTAssertEqual(HomeBriefCard.meta(quote, now: now, calendar: calendar), "12:40")
        XCTAssertEqual(
            HomeBriefCard.meta(question, now: now, calendar: calendar),
            "12:40 · \(L10n.text("still unresolved"))")
        XCTAssertEqual(
            HomeBriefCard.meta(unanchored, now: now, calendar: calendar), L10n.text("closed"),
            "a line without transcript evidence has no moment to show")
    }

    func testOpenCommitmentsSayWhenTheyAreDue() {
        func status(dueIn days: Double?) -> String? {
            HomeBriefCard.status(
                .open(due: days.map { now.addingTimeInterval($0 * 86_400) }), now: now, calendar: calendar)
        }
        XCTAssertEqual(status(dueIn: nil), L10n.text("open"))
        XCTAssertEqual(status(dueIn: 0), L10n.text("open, due today"))
        XCTAssertEqual(status(dueIn: 1), L10n.text("open, due tomorrow"))
        XCTAssertEqual(status(dueIn: -3), L10n.text("open, overdue"))
        XCTAssertNotEqual(status(dueIn: 5), L10n.text("open"))
        XCTAssertNil(HomeBriefCard.status(.said, now: now, calendar: calendar))
    }

    func testPeopleReadAsYouTheirNameOrTheirLabel() {
        func person(isMe: Bool, name: String?) -> MeetingBriefLines.Person {
            MeetingBriefLines.Person(
                speakerID: SpeakerID(), personID: nil, isMe: isMe, label: "S2", displayName: name, lines: [])
        }
        XCTAssertEqual(HomeBriefCard.name(person(isMe: true, name: nil)), L10n.text("You"))
        XCTAssertEqual(HomeBriefCard.name(person(isMe: false, name: "Marta")), "Marta")
        XCTAssertEqual(HomeBriefCard.name(person(isMe: false, name: nil)), "S2")
    }

    func testSourceFactsGiveTheDayAndLength() {
        let meeting = Meeting(title: "Sync", startedAt: now, endedAt: now.addingTimeInterval(31 * 60))
        XCTAssertTrue(HomeBriefCard.sourceFacts(meeting).hasSuffix(" · \(L10n.format("%d min", 31))"))
        let open = Meeting(title: "Sync", startedAt: now)
        XCTAssertFalse(HomeBriefCard.sourceFacts(open).contains("·"))
    }

    private func line(
        _ kind: MeetingBriefLines.Kind, _ status: MeetingBriefLines.Status, segment: UUID?, time: TimeInterval
    ) -> MeetingBriefLines.Line {
        MeetingBriefLines.Line(kind: kind, text: "Line", segmentID: segment, time: time, status: status)
    }
}
