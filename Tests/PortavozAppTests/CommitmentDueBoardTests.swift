import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

final class CommitmentDueBoardTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday 16 Sep 2026, 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_789_552_800)
    private let day: TimeInterval = 86_400

    private func confirmed(
        _ title: String,
        dueIn days: Double?,
        assignee: CommitmentAssignee = .me,
        name: String? = nil,
        status: CommitmentStatus = .confirmed
    ) -> CommitmentRadarItem {
        CommitmentRadarItem(
            commitment: Commitment(
                title: title,
                status: status,
                assignee: assignee,
                dueAt: days.map { now.addingTimeInterval($0 * day) },
                createdAt: now),
            assigneeDisplayName: name,
            activity: .unchanged,
            sources: [],
            sourceCount: 0,
            history: [],
            historyCount: 0)
    }

    private func suggestion(
        _ text: String,
        revisitIn days: Double?,
        owner: CommitmentReviewQueueOwner? = nil,
        evidence: TranscriptEvidenceStatus = .current
    ) -> CommitmentReviewQueueItem {
        let meetingID = MeetingID()
        let segment = TranscriptSegment(
            meetingID: meetingID, speakerID: nil, channel: .system,
            text: text, startTime: 42, endTime: 45, isFinal: true)
        return CommitmentReviewQueueItem(
            meetingID: meetingID,
            meetingTitle: "Planning",
            meetingStartedAt: now,
            meetingEndedAt: now,
            actionItem: ActionItem(text: text),
            evidence: TranscriptEvidenceResolution(status: evidence, segments: [segment]),
            evidenceCount: 1,
            suggestedOwner: owner,
            reason: days.map { .deferredDue(revisitAt: now.addingTimeInterval($0 * day)) } ?? .newAfterMeeting)
    }

    private func board(
        _ confirmed: [CommitmentRadarItem], _ upcoming: [CommitmentReviewQueueItem] = []
    ) -> CommitmentDueBoard {
        CommitmentDueBoard(confirmed: confirmed, upcoming: upcoming, now: now, calendar: calendar)
    }

    func testColumnsRunFromOverdueThroughTheWeekToLater() {
        let board = board([
            confirmed("Late", dueIn: -1),
            confirmed("Now", dueIn: 0.2),
            confirmed("Friday", dueIn: 2),
            confirmed("Thursday", dueIn: 1),
            confirmed("Monday", dueIn: 5),
            confirmed("Far", dueIn: 30),
        ])

        let thursday = calendar.startOfDay(for: now.addingTimeInterval(day))
        let friday = calendar.startOfDay(for: now.addingTimeInterval(2 * day))
        XCTAssertEqual(
            board.lanes.map(\.column),
            [.overdue, .today, .day(thursday), .day(friday), .nextWeek, .later])
        XCTAssertEqual(
            board.lanes.map { $0.chips.map(\.task) },
            [["Late"], ["Now"], ["Thursday"], ["Friday"], ["Monday"], ["Far"]])
    }

    func testAnchorsStayAndEmptyDaysAndLaterDoNot() {
        let board = board([confirmed("Monday", dueIn: 5)])

        XCTAssertEqual(board.lanes.map(\.column), [.overdue, .today, .nextWeek])
        XCTAssertFalse(board.isEmpty)
        XCTAssertTrue(self.board([]).isEmpty)
    }

    func testOnlyOpenDatedWorkAndPutOffSuggestionsAreOnTheBoard() {
        let board = board(
            [
                confirmed("No date", dueIn: nil),
                confirmed("Done", dueIn: 1, status: .done),
                confirmed("Open", dueIn: 1),
            ],
            [suggestion("Waiting now", revisitIn: nil), suggestion("Put off", revisitIn: 1)])

        let chips = board.lanes.flatMap(\.chips)
        XCTAssertEqual(chips.map(\.task), ["Open", "Put off"], "confirmed work first on the same day")
        XCTAssertEqual(chips.map(\.isConfirmed), [true, false])
    }

    func testOverdueCountStaysExactWhenItsReadWasCut() {
        let late = (1...3).map { confirmed("Late \($0)", dueIn: -Double($0)) }
        let board = CommitmentDueBoard(
            CommitmentDueBoard.Work(
                overdue: CommitmentRadarPage(items: late, totalCount: 250),
                fromToday: CommitmentRadarPage(items: [confirmed("Now", dueIn: 0.2)], totalCount: 1)),
            now: now,
            calendar: calendar)

        XCTAssertEqual(board.lanes.map(\.count), [250, 1, 0])
        XCTAssertEqual(board.lanes.first?.chips.map(\.task), ["Late 3", "Late 2", "Late 1"])
    }

    func testChipsOpenTheCommitmentOrTheSuggestionsMoment() throws {
        let item = confirmed("Open", dueIn: 1)
        let current = suggestion("Current", revisitIn: 1)
        let stale = suggestion("Stale", revisitIn: 1, evidence: .stale)
        let chips = board([item], [current, stale]).lanes.flatMap(\.chips)

        XCTAssertEqual(chips.map(\.target), [
            .commitment(item.id),
            .meeting(current.meetingID, at: 42),
            .meeting(stale.meetingID, at: nil),
        ])
    }

    func testOwnersAreYouOrTheirNameAndShareOneTintAcrossChips() throws {
        let personID = PersonID()
        let ana = CommitmentReviewQueueOwner(personID: personID, displayName: "Ana")
        let chips = board(
            [
                confirmed("Mine", dueIn: 1),
                confirmed("Hers", dueIn: 1, assignee: .person(personID), name: "Ana"),
                confirmed("Nobody's", dueIn: 1, assignee: .unassigned),
            ],
            [suggestion("Also hers", revisitIn: 1, owner: ana)]).lanes.flatMap(\.chips)

        XCTAssertEqual(chips.map(\.owner), ["You", "Ana", nil, "Ana"])
        XCTAssertEqual(chips[0].tint, .you)
        XCTAssertEqual(chips[2].tint, .grey)
        guard case .hue = chips[1].tint else { return XCTFail("a named owner takes a hue") }
        XCTAssertEqual(chips[1].tint, chips[3].tint)
    }

    func testWeekEndFollowsTheCalendarsFirstWeekday() {
        var sundayWeeks = calendar
        sundayWeeks.firstWeekday = 1
        // Sunday 20 Sep is next week when weeks start on Sunday, this week when on Monday.
        let sunday = confirmed("Sunday", dueIn: 4)
        let monday = CommitmentDueBoard(confirmed: [sunday], upcoming: [], now: now, calendar: calendar)
        let sundayStart = CommitmentDueBoard(confirmed: [sunday], upcoming: [], now: now, calendar: sundayWeeks)

        XCTAssertEqual(monday.lanes.map(\.column).count, 4)
        XCTAssertEqual(sundayStart.lanes.map(\.column), [.overdue, .today, .nextWeek])
        XCTAssertEqual(sundayStart.lanes.last?.chips.map(\.task), ["Sunday"])
    }
}
