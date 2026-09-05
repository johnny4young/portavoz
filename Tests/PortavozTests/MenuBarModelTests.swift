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
        XCTAssertEqual(model.state.briefOffer?.event, fixture.event)
        XCTAssertEqual(client.calls, [.nextEvent, .briefOffer, .observe])
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

    func testCancelledCalendarLoadPublishesNoStaleResidentState() async {
        let fixture = MenuBarModelFixture()
        let client = MenuBarModelClientFake(fixture: fixture)
        client.nextEventDelayNanoseconds = 1_000_000_000
        let model = MenuBarModel(client: client)
        let observation = Task { await model.observe() }
        await Task.yield()

        observation.cancel()
        await observation.value

        XCTAssertEqual(client.calls, [.nextEvent])
        XCTAssertNil(model.state.nextEvent)
        XCTAssertNil(model.state.briefOffer)
        XCTAssertEqual(model.state.loadPhase, .loading)
    }

    func testDisposableCalendarFixtureRequiresSeedAndResolvesOnlyOpaqueID() async throws {
        let absent = AppUpcomingEventSource(
            arguments: [],
            usesTemporaryStore: true)
        let seeded = AppUpcomingEventSource(
            arguments: ["-seed-brief"],
            usesTemporaryStore: true)

        let absentEvent = await absent.nextEvent()
        XCTAssertNil(absentEvent)
        let event = await seeded.nextEvent()
        let matched = try await seeded.upcomingEvent(
            matching: "ui-test-upcoming-rollout")
        let mismatched = try await seeded.upcomingEvent(
            matching: "wrong-event")
        XCTAssertEqual(event?.id, "ui-test-upcoming-rollout")
        XCTAssertEqual(matched, event)
        XCTAssertNil(mismatched)
    }

    func testBriefPreviewAndRetryKeepOneProposalIdentity() async throws {
        let fixture = MenuBarModelFixture()
        let client = MenuBarModelClientFake(fixture: fixture)
        client.skillFailuresRemaining = 1
        let model = MenuBarModel(client: client)
        await model.observe()
        let offer = try XCTUnwrap(model.state.briefOffer)

        model.requestBrief(offer)
        await model.prepareRequestedBrief()
        let target = try XCTUnwrap(model.state.briefConfirmTarget)

        guard case .failed = await model.confirmBrief(target) else {
            return XCTFail("the first recoverable effect must keep confirmation open")
        }
        guard case .succeeded = await model.confirmBrief(target) else {
            return XCTFail("the original proposal must remain retryable")
        }

        XCTAssertNil(model.state.briefOffer)
        XCTAssertNil(model.state.briefConfirmTarget)
        XCTAssertEqual(model.state.preparedBrief?.event, fixture.event)
        XCTAssertEqual(model.state.preparedEventID, fixture.event.id)
        let proposalIDs = client.calls.compactMap { call -> UUID? in
            guard case .perform(let proposalID, _) = call else { return nil }
            return proposalID
        }
        XCTAssertEqual(proposalIDs, [target.proposalID, target.proposalID])
    }

    func testCancelledConfirmationCannotPublishASuccessfulResult() async throws {
        let fixture = MenuBarModelFixture()
        let client = MenuBarModelClientFake(fixture: fixture)
        client.performDelayNanoseconds = 1_000_000_000
        let model = MenuBarModel(client: client)
        await model.observe()
        let offer = try XCTUnwrap(model.state.briefOffer)
        model.requestBrief(offer)
        await model.prepareRequestedBrief()
        let target = try XCTUnwrap(model.state.briefConfirmTarget)
        let execution = Task { await model.confirmBrief(target) }
        await Task.yield()

        execution.cancel()
        guard case .failed = await execution.value else {
            return XCTFail("a cancelled presentation must not publish success")
        }

        XCTAssertEqual(model.state.briefConfirmTarget?.proposalID, target.proposalID)
        XCTAssertNil(model.state.preparedBrief)
        XCTAssertEqual(model.state.briefOffer?.id, offer.id)
    }
}

private struct MenuBarModelFixture {
    let meetings: [MenuBarMeeting]
    let event: UpcomingEvent
    let brief: MeetingBrief

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
            id: "event-design-sync",
            title: "Design sync",
            startDate: Date(timeIntervalSince1970: 1_790_000_000),
            attendees: ["Ana"])
        brief = MeetingBrief(
            event: event,
            related: [],
            openItems: [],
            whatToKnow: [])
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
    case briefOffer
    case prepareBrief
    case perform(UUID, String)
    case dismiss(String)
    case observe
}

@MainActor
private final class MenuBarModelClientFake: MenuBarModelClient {
    var updates: [MenuBarUpdate]
    var event: UpcomingEvent?
    var offer: PreMeetingBriefOffer?
    var brief: MeetingBrief?
    var skillFailuresRemaining = 0
    var nextEventDelayNanoseconds: UInt64 = 0
    var performDelayNanoseconds: UInt64 = 0
    var calls: [MenuBarModelCall] = []

    init(fixture: MenuBarModelFixture) {
        updates = fixture.updates
        event = fixture.event
        offer = PreMeetingBriefOffer(event: fixture.event)
        brief = fixture.brief
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

    func nextMenuBarEvent() async -> UpcomingEvent? {
        calls.append(.nextEvent)
        if nextEventDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: nextEventDelayNanoseconds)
        }
        return event
    }

    func menuBarBriefOffer(
        for event: UpcomingEvent
    ) async -> PreMeetingBriefOffer? {
        calls.append(.briefOffer)
        return offer?.event == event ? offer : nil
    }

    func prepareMenuBarBrief(
        for event: UpcomingEvent
    ) async -> MeetingBrief? {
        calls.append(.prepareBrief)
        return brief?.event == event ? brief : nil
    }

    func performMenuBarBriefSkill(
        proposalID: UUID,
        offer: PreMeetingBriefOffer,
        approvedBrief: MeetingBrief
    ) async throws -> String? {
        calls.append(.perform(proposalID, offer.id))
        if performDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: performDelayNanoseconds)
        }
        guard approvedBrief.event == offer.event else { return "stale" }
        if skillFailuresRemaining > 0 {
            skillFailuresRemaining -= 1
            return "failed"
        }
        return nil
    }

    func dismissMenuBarBriefOffer(
        _ offer: PreMeetingBriefOffer
    ) async throws {
        calls.append(.dismiss(offer.id))
    }
}
