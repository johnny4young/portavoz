import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class InsightsModelTests: XCTestCase {
    func testObservationPublishesOneCompleteReadModel() async throws {
        let fixture = InsightsModelFixture()
        let client = InsightsModelClientFake(updates: fixture.updates)
        let model = InsightsModel(client: client, clock: { fixture.now })

        await model.observe(scope: .week)

        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.scope, .week)
        XCTAssertEqual(model.state.readModel?.meetings.map(\.id), [fixture.meeting.id])
        XCTAssertEqual(model.state.readModel?.facts, fixture.facts)
        XCTAssertEqual(model.state.readModel?.balance, fixture.balance)
        XCTAssertEqual(client.calls.map(\.scope), [.week])
        XCTAssertEqual(client.calls.first?.now, fixture.now)
    }

    func testObservationDistinguishesEmptyDegradedAndUnavailableState() async {
        let fixture = InsightsModelFixture()

        let emptyClient = InsightsModelClientFake(updates: [
            .meetings([]), .facts(fixture.emptyFacts),
            .voiceBalance(fixture.emptyBalance), .findingInputs([:]),
        ])
        let empty = InsightsModel(client: emptyClient, clock: { fixture.now })
        await empty.observe(scope: .week)
        XCTAssertEqual(empty.state.phase, .empty)
        XCTAssertEqual(empty.state.readModel?.stats.totalMeetings, 0)

        let degradedClient = InsightsModelClientFake(updates: [
            .meetings([fixture.meeting]), .failed(.facts),
            .voiceBalance(fixture.balance), .findingInputs(fixture.findingInputs),
        ])
        let degraded = InsightsModel(client: degradedClient, clock: { fixture.now })
        await degraded.observe(scope: .week)
        XCTAssertEqual(degraded.state.phase, .degraded(failures: 1))
        XCTAssertEqual(degraded.state.readModel?.meetings.map(\.id), [fixture.meeting.id])
        XCTAssertNil(degraded.state.readModel?.facts)

        let failedClient = InsightsModelClientFake(
            updates: InsightsSection.allCases.map(InsightsUpdate.failed))
        let failed = InsightsModel(client: failedClient, clock: { fixture.now })
        await failed.observe(scope: .week)
        XCTAssertEqual(failed.state.phase, .failed)
        XCTAssertEqual(failed.state.readModel?.stats.totalMeetings, 0)
    }

    func testLaterUpdatesReplaceOnlyTheirProjectionAndRecomputeFindings() async {
        let fixture = InsightsModelFixture()
        let renamedFacts = InsightsLibraryFacts(
            topParticipants: [InsightsParticipant(name: "Qord2M", meetings: 1)],
            openActionItems: 0,
            doneActionItems: 1)
        let client = InsightsModelClientFake(updates: fixture.updates + [
            .facts(renamedFacts),
        ])
        let model = InsightsModel(client: client, clock: { fixture.now })

        await model.observe(scope: .week)

        XCTAssertEqual(model.state.readModel?.facts, renamedFacts)
        XCTAssertEqual(model.state.readModel?.balance, fixture.balance)
        XCTAssertTrue(model.state.readModel?.topics.isEmpty == true)
    }

    func testScopeRestartRecomputesTotalsWithoutGlobalVersion() async {
        let fixture = InsightsModelFixture()
        let previousMonth = Meeting(
            title: "Older",
            startedAt: fixture.calendar.date(
                byAdding: .month,
                value: -1,
                to: fixture.now)!)
        let client = InsightsModelClientFake(updates: [
            .meetings([fixture.meeting, previousMonth]),
            .facts(fixture.facts),
            .voiceBalance(fixture.balance),
            .findingInputs(fixture.findingInputs),
        ])
        let model = InsightsModel(client: client, clock: { fixture.now })

        await model.observe(scope: .week)
        let weekCount = model.state.readModel?.totals.count
        await model.observe(scope: .year)

        XCTAssertEqual(weekCount, 1)
        XCTAssertEqual(model.state.readModel?.totals.count, 2)
        XCTAssertEqual(client.calls.map(\.scope), [.week, .year])
    }
}

private struct InsightsModelFixture {
    let now = Date(timeIntervalSince1970: 1_789_004_800)
    let meeting: Meeting
    let facts: InsightsLibraryFacts
    let balance: InsightsVoiceBalance
    let findingInputs: [MeetingID: InsightsFindingInput]

    init() {
        let started = Date(timeIntervalSince1970: 1_789_004_800 - 3_600)
        meeting = Meeting(
            title: "Planning",
            startedAt: started,
            endedAt: started.addingTimeInterval(1_800))
        facts = InsightsLibraryFacts(
            topParticipants: [InsightsParticipant(name: "Ana", meetings: 1)],
            openActionItems: 1,
            doneActionItems: 0)
        balance = InsightsVoiceBalance(
            participants: [InsightsParticipantVoice(
                name: "Ana",
                meetings: 1,
                theirSeconds: 600,
                myShareWithThem: 0.4)],
            myOverallShare: 0.4,
            hasData: true)
        findingInputs = [meeting.id: InsightsFindingInput(
            transcript: "Qord2M sigue pendiente.",
            summaryMarkdown: "## Resumen\n- Pendiente",
            actionItemCount: 0)]
    }

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    var emptyFacts: InsightsLibraryFacts {
        InsightsLibraryFacts(
            topParticipants: [],
            openActionItems: 0,
            doneActionItems: 0)
    }

    var emptyBalance: InsightsVoiceBalance {
        InsightsVoiceBalance(
            participants: [],
            myOverallShare: 0,
            hasData: false)
    }

    var updates: [InsightsUpdate] {
        [
            .meetings([meeting]),
            .facts(facts),
            .voiceBalance(balance),
            .findingInputs(findingInputs),
        ]
    }
}

@MainActor
private final class InsightsModelClientFake: InsightsModelClient {
    struct Call {
        let scope: InsightsScope
        let now: Date
    }

    let updates: [InsightsUpdate]
    var calls: [Call] = []

    init(updates: [InsightsUpdate]) {
        self.updates = updates
    }

    func observeInsights(
        scope: InsightsScope,
        now: Date
    ) -> AsyncStream<InsightsUpdate> {
        calls.append(Call(scope: scope, now: now))
        return AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            continuation.finish()
        }
    }
}
