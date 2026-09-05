import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class StandingSupervisorLifecycleTests: XCTestCase {
    func testStopRejectsLateCalendarReadWithoutInstallingWake() async throws {
        let fixture = try await Fixture(gateRead: true)
        await fixture.supervisor.start()
        await fulfillment(of: [fixture.source.readStarted], timeout: 2)
        let worker = await fixture.supervisor.worker
        XCTAssertNotNil(worker)

        await fixture.supervisor.stop()
        await fixture.source.releaseRead()
        await worker?.value

        let wake = await fixture.supervisor.wakeTask
        let receipts = try await fixture.store.standingSkillExecutionReceipts(limit: 20)
        await fixture.finish()
        XCTAssertNil(wake, "a retired calendar read must not recreate a wake")
        XCTAssertTrue(receipts.isEmpty)
    }

    func testCaptureRejectsLateWakeAndResumesExactlyOneBrief() async throws {
        let fixture = try await Fixture(gateRead: true)
        await fixture.supervisor.start()
        await fulfillment(of: [fixture.source.readStarted], timeout: 2)
        let worker = await fixture.supervisor.worker

        fixture.capture.update(.active)
        await fixture.supervisor.suspendForCapture()
        await fixture.source.releaseRead()
        await worker?.value
        let wakeDuringCapture = await fixture.supervisor.wakeTask
        let receiptsDuringCapture = try await fixture.store
            .standingSkillExecutionReceipts(limit: 20)

        fixture.capture.update(.inactive)
        try await fixture.supervisor.reconcileNow()
        let receipts = try await fixture.store.standingSkillExecutionReceipts(limit: 20)
        let prepared = await fixture.preparer.eventIDs
        await fixture.finish()

        XCTAssertNil(wakeDuringCapture)
        XCTAssertTrue(receiptsDuringCapture.isEmpty)
        XCTAssertEqual(prepared, [Fixture.event.id])
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.record.state, .succeeded)
    }

    func testRetiredCalendarReadCannotCancelNewWorkersWake() async throws {
        let fixture = try await Fixture(gateRead: true)
        await fixture.supervisor.start()
        await fulfillment(of: [fixture.source.readStarted], timeout: 2)
        let retiredWorker = await fixture.supervisor.worker
        await fixture.supervisor.stop()

        try await fixture.supervisor.reconcileNow()
        let currentWake = await fixture.supervisor.wakeTask
        XCTAssertNotNil(currentWake)
        await fixture.source.releaseRead()
        await retiredWorker?.value
        let currentWakeWasCancelled = currentWake?.isCancelled
        let receipts = try await fixture.store.standingSkillExecutionReceipts(limit: 20)
        await fixture.finish()

        XCTAssertEqual(currentWakeWasCancelled, false)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.record.state, .succeeded)
    }

    func testConcurrentStartOwnsOnePendingSubscription() async throws {
        let fixture = try await Fixture(gateSubscription: true)
        let firstStart = Task { await fixture.supervisor.start() }
        await fulfillment(of: [fixture.source.subscriptionStarted], timeout: 2)
        await fixture.supervisor.start()
        let count = await fixture.source.subscriptionCount

        await fixture.source.releaseSubscription()
        await firstStart.value
        try await fixture.supervisor.reconcileNow()
        await fixture.finish()
        XCTAssertEqual(count, 1, "start must reserve ownership before awaiting EventKit")
    }

    func testStopWhileSubscribingCannotResurrectObservation() async throws {
        let fixture = try await Fixture(gateSubscription: true)
        let start = Task { await fixture.supervisor.start() }
        await fulfillment(of: [fixture.source.subscriptionStarted], timeout: 2)
        let observer = await fixture.supervisor.observationTask
        await fixture.supervisor.stop()
        await fixture.source.releaseSubscription()
        await start.value
        await observer?.value
        let currentObserver = await fixture.supervisor.observationTask
        await fixture.finish()

        XCTAssertNil(currentObserver)
    }
}

private struct Fixture: Sendable {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let event = UpcomingEvent(
        id: "synthetic-standing-event",
        title: "Public synthetic planning",
        startDate: now.addingTimeInterval(30 * 60),
        attendees: [])

    let store: MeetingStore
    let source: GatedStandingLifecycleSource
    let preparer: LifecycleBriefPreparer
    let capture: AppResourceCaptureState
    let supervisor: StandingPreMeetingBriefSupervisor

    init(gateRead: Bool = false, gateSubscription: Bool = false) async throws {
        store = try MeetingStore.inMemory()
        _ = try await CreateStandingSkillRule(store: store, now: { Self.now })
            .execute(CreateStandingSkillRuleRequest(template: .prepareEveryUpcomingBrief))
        source = GatedStandingLifecycleSource(
            gateRead: gateRead,
            gateSubscription: gateSubscription)
        preparer = LifecycleBriefPreparer()
        capture = AppResourceCaptureState()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        supervisor = StandingPreMeetingBriefSupervisor(
            store: store, preparer: preparer, events: source,
            captureState: capture, calendar: calendar, now: { Self.now })
    }

    func finish() async {
        let worker = await supervisor.worker
        let observer = await supervisor.observationTask
        await supervisor.stop()
        await source.finish()
        await worker?.value
        await observer?.value
    }
}

/// Deliberately ignores task cancellation while reading/subscribing. A
/// platform callback may still return after its owner has stopped. Tests
/// release exact continuations and join the captured task instead of sleeping.
private actor GatedStandingLifecycleSource: StandingPreMeetingBriefEventSource {
    nonisolated let readStarted = XCTestExpectation(description: "calendar read entered")
    nonisolated let subscriptionStarted = XCTestExpectation(description: "subscription entered")
    private let gateRead: Bool
    private let gateSubscription: Bool
    private var readCount = 0
    private(set) var subscriptionCount = 0
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var subscriptionContinuation: CheckedContinuation<Void, Never>?
    private let changes: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    init(gateRead: Bool, gateSubscription: Bool) {
        self.gateRead = gateRead
        self.gateSubscription = gateSubscription
        (changes, changeContinuation) = AsyncStream.makeStream()
    }

    func upcomingStandingBriefEvents() async -> [UpcomingEvent] {
        readCount += 1
        if gateRead, readCount == 1 {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
                readStarted.fulfill()
            }
        }
        return [Fixture.event]
    }

    func standingBriefEventChanges() async -> AsyncStream<Void> {
        subscriptionCount += 1
        if gateSubscription, subscriptionCount == 1 {
            await withCheckedContinuation { continuation in
                subscriptionContinuation = continuation
                subscriptionStarted.fulfill()
            }
        }
        return changes
    }

    func upcomingEvent(matching identifier: String) -> UpcomingEvent? {
        identifier == Fixture.event.id ? Fixture.event : nil
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func releaseSubscription() {
        subscriptionContinuation?.resume()
        subscriptionContinuation = nil
    }

    func finish() {
        releaseRead()
        releaseSubscription()
        changeContinuation.finish()
    }
}

private actor LifecycleBriefPreparer: StandingPreMeetingBriefPreparing {
    private(set) var eventIDs: [String] = []

    func prepareStandingPreMeetingBrief(for event: UpcomingEvent) -> MeetingBrief {
        eventIDs.append(event.id)
        return MeetingBrief(event: event, related: [], openItems: [], whatToKnow: [])
    }
}
