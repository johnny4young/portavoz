import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class InsightsReadModelTests: XCTestCase {
    func testReadModelCombinesScopeTotalsAndFindingEvidence() {
        let fixture = InsightsReadModelFixture()
        let current = fixture.meeting(daysFromNow: -1, duration: 1_800)
        let second = fixture.meeting(daysFromNow: -2, duration: 900)
        let previous = fixture.meeting(daysFromNow: -8, duration: 600)
        let input = InsightsFindingInput(
            transcript: "El rollout de Qord2M sigue pendiente.",
            summaryMarkdown: "## Resumen\n- Sin acuerdo",
            actionItemCount: 0)

        let model = InsightsReadModel.compute(
            meetings: [current, second, previous],
            facts: nil,
            balance: nil,
            findingInputs: [current.id: input, second.id: input],
            scope: .week,
            now: fixture.now,
            calendar: fixture.calendar)

        XCTAssertEqual(model.stats.totalMeetings, 3)
        XCTAssertEqual(model.totals.count, 2)
        XCTAssertEqual(model.totals.previousCount, 1)
        XCTAssertEqual(model.totals.seconds, 2_700)
        XCTAssertEqual(model.noDecision?.count, 2)
        XCTAssertEqual(model.topics.map(\.term), ["Qord2M"])
    }

    func testDecisionSectionAndActionItemBothCountAsDecisionEvidence() {
        let fixture = InsightsReadModelFixture()
        let first = fixture.meeting(daysFromNow: -1, duration: 1_800)
        let second = fixture.meeting(daysFromNow: -2, duration: 900)

        let model = InsightsReadModel.compute(
            meetings: [first, second],
            facts: nil,
            balance: nil,
            findingInputs: [
                first.id: InsightsFindingInput(
                    transcript: "Qord2M",
                    summaryMarkdown: "## Decisions\n- Ship Friday",
                    actionItemCount: 0),
                second.id: InsightsFindingInput(
                    transcript: "Qord2M",
                    summaryMarkdown: "## Resumen\n- Seguimiento",
                    actionItemCount: 1),
            ],
            scope: .week,
            now: fixture.now,
            calendar: fixture.calendar)

        XCTAssertNil(model.noDecision)
    }

    func testConfirmedParticipantNamesNeverBecomeRecurringTopics() {
        let fixture = InsightsReadModelFixture()
        let first = fixture.meeting(daysFromNow: -1, duration: 1_800)
        let second = fixture.meeting(daysFromNow: -2, duration: 900)
        let input = InsightsFindingInput(
            transcript: "Revisamos con Aurora el alcance.",
            summaryMarkdown: nil,
            actionItemCount: 0)
        let facts = InsightsLibraryFacts(
            topParticipants: [InsightsParticipant(name: "Aurora", meetings: 2)],
            openActionItems: 0,
            doneActionItems: 0)

        let model = InsightsReadModel.compute(
            meetings: [first, second],
            facts: facts,
            balance: nil,
            findingInputs: [first.id: input, second.id: input],
            scope: .week,
            now: fixture.now,
            calendar: fixture.calendar)

        XCTAssertTrue(model.topics.isEmpty)
    }
}

private struct InsightsReadModelFixture {
    let now = Date(timeIntervalSince1970: 1_789_004_800)
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func meeting(daysFromNow: Int, duration: TimeInterval) -> Meeting {
        let start = calendar.date(
            byAdding: .day,
            value: daysFromNow,
            to: now)!
        return Meeting(
            title: "Planning",
            startedAt: start,
            endedAt: start.addingTimeInterval(duration))
    }
}
