import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class MenuBarModelTests: XCTestCase {
    func testObservationCombinesRecentMeetingsPendingCountsAndCalendar() async {
        let fixture = MenuBarModelFixture()
        let client = MenuBarModelClientFake(fixture: fixture)
        let model = MenuBarModel(client: client)

        await model.observe()

        XCTAssertEqual(model.state.loadPhase, .loaded)
        XCTAssertEqual(model.state.meetings, fixture.meetings)
        XCTAssertEqual(model.state.pendingByMeeting, [fixture.meetings[0].id: 2])
        XCTAssertEqual(model.state.nextEvent, fixture.event)
        XCTAssertEqual(client.calls, [.nextEvent, .observe])
    }

    func testObservationDistinguishesEmptyDegradedAndFailedState() async {
        let fixture = MenuBarModelFixture()

        let emptyClient = MenuBarModelClientFake(fixture: fixture)
        emptyClient.updates = [.meetings([]), .pendingCounts([:])]
        emptyClient.event = nil
        let emptyModel = MenuBarModel(client: emptyClient)
        await emptyModel.observe()
        XCTAssertEqual(emptyModel.state.loadPhase, .empty)

        let degradedClient = MenuBarModelClientFake(fixture: fixture)
        degradedClient.updates = [
            .meetings(fixture.meetings),
            .failed(.pendingCounts),
        ]
        let degradedModel = MenuBarModel(client: degradedClient)
        await degradedModel.observe()
        XCTAssertEqual(degradedModel.state.loadPhase, .degraded(failures: 1))
        XCTAssertEqual(degradedModel.state.meetings, fixture.meetings)

        let failedClient = MenuBarModelClientFake(fixture: fixture)
        failedClient.updates = [.failed(.meetings), .failed(.pendingCounts)]
        let failedModel = MenuBarModel(client: failedClient)
        await failedModel.observe()
        XCTAssertEqual(failedModel.state.loadPhase, .failed)
    }

    func testLaterSectionFailurePreservesLastHealthySnapshot() async {
        let fixture = MenuBarModelFixture()
        let client = MenuBarModelClientFake(fixture: fixture)
        client.updates.append(.failed(.meetings))
        let model = MenuBarModel(client: client)

        await model.observe()

        XCTAssertEqual(model.state.loadPhase, .degraded(failures: 1))
        XCTAssertEqual(model.state.meetings, fixture.meetings)
        XCTAssertEqual(model.state.pendingByMeeting[fixture.meetings[0].id], 2)
    }
}

private struct MenuBarModelFixture {
    let meetings: [MenuBarMeeting]
    let event: UpcomingEvent

    init() {
        meetings = [
            MenuBarMeeting(
                id: MeetingID(),
                title: "Planning",
                startedAt: Date(timeIntervalSince1970: 1_789_000_000)),
            MenuBarMeeting(
                id: MeetingID(),
                title: "Review",
                startedAt: Date(timeIntervalSince1970: 1_788_000_000)),
        ]
        event = UpcomingEvent(
            title: "Design sync",
            startDate: Date(timeIntervalSince1970: 1_790_000_000),
            attendees: ["Ana"])
    }

    var updates: [MenuBarUpdate] {
        [
            .pendingCounts([meetings[0].id: 2]),
            .meetings(meetings),
        ]
    }
}

private enum MenuBarModelCall: Equatable {
    case nextEvent
    case observe
}

@MainActor
private final class MenuBarModelClientFake: MenuBarModelClient {
    var updates: [MenuBarUpdate]
    var event: UpcomingEvent?
    var calls: [MenuBarModelCall] = []

    init(fixture: MenuBarModelFixture) {
        updates = fixture.updates
        event = fixture.event
    }

    func observeMenuBar() -> AsyncStream<MenuBarUpdate> {
        calls.append(.observe)
        return AsyncStream { continuation in
            for update in updates {
                continuation.yield(update)
            }
            continuation.finish()
        }
    }

    func nextMenuBarEvent() -> UpcomingEvent? {
        calls.append(.nextEvent)
        return event
    }
}
