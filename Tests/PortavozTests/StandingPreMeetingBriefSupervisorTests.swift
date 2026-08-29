import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

@testable import portavoz_app

final class StandingPreMeetingBriefSupervisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBurstSignalsKeepOneSerializedPreparation() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await createRule(in: store)
        let event = upcomingEvent(id: "burst-event", offset: 30 * 60)
        let source = StandingSupervisorEventSource(events: [event])
        let preparer = GatedStandingBriefPreparer()
        let supervisor = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source)

        await supervisor.start()
        await preparer.waitUntilStarted()
        for _ in 0..<20 { await supervisor.kick() }
        await preparer.release()

        await waitUntil {
            let pendingIsEmpty = (try? await store
                .pendingStandingSkillExecutions())?.isEmpty == true
            let callCount = await preparer.callCount
            return pendingIsEmpty && callCount == 1
        }
        try? await Task.sleep(for: .milliseconds(30))
        let callCount = await preparer.callCount
        XCTAssertEqual(callCount, 1)
        await supervisor.stop()
    }

    func testExplicitReconciliationWaitsForTheSerializedOwner() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await createRule(in: store)
        let event = upcomingEvent(id: "explicit-retry", offset: 30 * 60)
        let source = StandingSupervisorEventSource(events: [event])
        let preparer = GatedStandingBriefPreparer()
        let supervisor = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source)
        let completion = StandingReconciliationCompletion()

        let request = Task {
            await supervisor.reconcileNow()
            await completion.markFinished()
        }
        await preparer.waitUntilStarted()
        let finishedBeforeRelease = await completion.isFinished
        XCTAssertFalse(finishedBeforeRelease)
        await preparer.release()
        await request.value

        let finishedAfterRelease = await completion.isFinished
        XCTAssertTrue(finishedAfterRelease)
        let history = try await store.standingSkillExecutionReceipts(limit: 20)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.record.state, .succeeded)
        XCTAssertEqual(history.first?.hasArtifact, true)
        await supervisor.stop()
    }

    func testActiveCaptureDefersUntilExplicitInactiveSignal() async throws {
        let calendar = utcCalendar()
        XCTAssertEqual(
            StandingPreMeetingBriefSupervisor.nextWakeDate(
                for: [],
                at: now,
                calendar: calendar),
            calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)))
        let wakeBase = calendar.startOfDay(for: now)
            .addingTimeInterval(8 * 60 * 60)
        let leadEvent = UpcomingEvent(
            id: "future-lead-window",
            title: "Private calendar title",
            startDate: wakeBase.addingTimeInterval(3 * 60 * 60),
            attendees: [])
        XCTAssertEqual(
            StandingPreMeetingBriefSupervisor.nextWakeDate(
                for: [leadEvent],
                at: wakeBase,
                calendar: calendar),
            wakeBase.addingTimeInterval(60 * 60))
        let store = try MeetingStore.inMemory()
        _ = try await createRule(in: store)
        let event = upcomingEvent(id: "capture-deferred", offset: 30 * 60)
        let source = StandingSupervisorEventSource(events: [event])
        let preparer = RecordingStandingBriefPreparer()
        let capture = AppResourceCaptureState()
        capture.update(.active)
        let supervisor = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source,
            capture: capture)

        await supervisor.start()
        try? await Task.sleep(for: .milliseconds(40))
        let eventIDsBeforeResume = await preparer.eventIDs
        let pendingBeforeResume = try await store
            .pendingStandingSkillExecutions()
        XCTAssertEqual(eventIDsBeforeResume, [])
        XCTAssertTrue(pendingBeforeResume.isEmpty)

        capture.update(.inactive)
        await supervisor.kick()
        await waitUntil { await preparer.eventIDs == [event.id] }
        await supervisor.stop()
    }

    func testCapturePreemptionPreservesOwnerAndResumesSameOccurrence() async throws {
        let store = try MeetingStore.inMemory()
        _ = try await createRule(in: store)
        let event = upcomingEvent(id: "capture-preempted", offset: 30 * 60)
        let source = StandingSupervisorEventSource(events: [event])
        let preparer = PreemptedStandingBriefPreparer()
        let capture = AppResourceCaptureState()
        let supervisor = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source,
            capture: capture)

        await supervisor.start()
        await preparer.waitUntilStarted()
        let initialPending = try await store.pendingStandingSkillExecutions()
        let proposalID = try XCTUnwrap(initialPending.first?.record.proposalID)

        capture.update(.active)
        await supervisor.suspendForCapture()
        await waitUntil { await preparer.cancellationCount == 1 }
        let preserved = try await store.pendingStandingSkillExecutions()
        XCTAssertEqual(preserved.first?.record.proposalID, proposalID)
        XCTAssertEqual(preserved.first?.record.state, .confirmed)

        capture.update(.inactive)
        await supervisor.kick()
        await waitUntil {
            (try? await store.standingSkillArtifact(
                proposalID: proposalID)) != nil
        }
        let resumedCallCount = await preparer.callCount
        XCTAssertEqual(resumedCallCount, 2)
        let history = try await store.skillExecutionHistory(
            proposalID: proposalID)
        XCTAssertEqual(history.map(\.kind), ["confirm", "begin", "succeed"])
        await supervisor.stop()
    }

    func testRelaunchResumesFailedOwnerBeforeNewEvent() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let first = upcomingEvent(id: "relaunch-owner", offset: 20 * 60)
        let second = upcomingEvent(id: "new-event", offset: 40 * 60)
        let source = StandingSupervisorEventSource(events: [second, first])
        let failedProposalID = UUID()
        let firstRun = makeExecutor(
            store: store,
            preparer: AlwaysFailingStandingBriefPreparer(),
            source: source,
            proposalID: failedProposalID)
        let firstOutcome = try await firstRun.execute((rule, first))
        XCTAssertEqual(firstOutcome, .failed(failedProposalID))

        let preparer = RecordingStandingBriefPreparer()
        let relaunched = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source)
        await relaunched.start()

        await waitUntil { await preparer.eventIDs == [first.id, second.id] }
        let history = try await store.skillExecutionHistory(
            proposalID: failedProposalID)
        XCTAssertEqual(
            history.map { "\($0.kind):\($0.attempt)" },
            [
                "confirm:1", "begin:1", "fail:1",
                "begin:2", "succeed:2"
            ])
        await relaunched.stop()
    }

    func testExplicitRetryResumesOnlyTheSelectedFailedOwner() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let first = upcomingEvent(id: "unselected-failure", offset: 20 * 60)
        let second = upcomingEvent(id: "selected-failure", offset: 40 * 60)
        let source = StandingSupervisorEventSource(events: [first, second])
        let firstProposalID = UUID()
        let secondProposalID = UUID()

        for (event, proposalID) in [
            (first, firstProposalID),
            (second, secondProposalID),
        ] {
            let executor = makeExecutor(
                store: store,
                preparer: AlwaysFailingStandingBriefPreparer(),
                source: source,
                proposalID: proposalID)
            let outcome = try await executor.execute((rule, event))
            XCTAssertEqual(outcome, .failed(proposalID))
        }

        let preparer = RecordingStandingBriefPreparer()
        let supervisor = makeSupervisor(
            store: store,
            preparer: preparer,
            source: source)
        await supervisor.retryNow(secondProposalID)

        let retriedEventIDs = await preparer.eventIDs
        XCTAssertEqual(retriedEventIDs, [second.id])
        let firstHistory = try await store.skillExecutionHistory(
            proposalID: firstProposalID)
        XCTAssertEqual(
            firstHistory.map { "\($0.kind):\($0.attempt)" },
            ["confirm:1", "begin:1", "fail:1"])
        let secondHistory = try await store.skillExecutionHistory(
            proposalID: secondProposalID)
        XCTAssertEqual(
            secondHistory.map { "\($0.kind):\($0.attempt)" },
            [
                "confirm:1", "begin:1", "fail:1",
                "begin:2", "succeed:2",
            ])
        await supervisor.stop()
    }

    private func makeSupervisor(
        store: MeetingStore,
        preparer: any StandingPreMeetingBriefPreparing,
        source: StandingSupervisorEventSource,
        capture: AppResourceCaptureState = AppResourceCaptureState()
    ) -> StandingPreMeetingBriefSupervisor {
        let instant = now
        return StandingPreMeetingBriefSupervisor(
            store: store,
            preparer: preparer,
            events: source,
            captureState: capture,
            calendar: utcCalendar(),
            now: { instant })
    }

    private func makeExecutor(
        store: MeetingStore,
        preparer: any StandingPreMeetingBriefPreparing,
        source: StandingSupervisorEventSource,
        proposalID: UUID
    ) -> ExecuteStandingPreMeetingBrief {
        let instant = now
        return ExecuteStandingPreMeetingBrief(
            store: store,
            preparer: preparer,
            events: source,
            calendar: utcCalendar(),
            timeout: .seconds(1),
            makeProposalID: { proposalID },
            now: { instant })
    }

    private func createRule(
        in store: MeetingStore
    ) async throws -> StandingSkillRule {
        let instant = now
        let outcome = try await CreateStandingSkillRule(
            store: store,
            now: { instant }
        ).execute(CreateStandingSkillRuleRequest(
            template: .prepareEveryUpcomingBrief))
        return switch outcome {
        case .created(let rule), .alreadyExists(let rule): rule
        }
    }

    private func upcomingEvent(
        id: String,
        offset: TimeInterval
    ) -> UpcomingEvent {
        UpcomingEvent(
            id: id,
            title: "Private calendar title",
            startDate: now.addingTimeInterval(offset),
            attendees: ["Ana"])
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for standing brief supervisor")
    }
}

private actor StandingSupervisorEventSource:
    StandingPreMeetingBriefEventSource {
    private var events: [UpcomingEvent]
    private let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(events: [UpcomingEvent]) {
        self.events = events
        (changes, continuation) = AsyncStream.makeStream()
    }

    func upcomingStandingBriefEvents() -> [UpcomingEvent] {
        events
    }

    func standingBriefEventChanges() -> AsyncStream<Void> {
        changes
    }

    func upcomingEvent(matching identifier: String) -> UpcomingEvent? {
        events.first { $0.id == identifier }
    }

    func replaceEvents(_ events: [UpcomingEvent]) {
        self.events = events
        continuation.yield()
    }
}

private actor GatedStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    private(set) var callCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async -> MeetingBrief {
        callCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return standingBrief(for: event)
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RecordingStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    private(set) var eventIDs: [String] = []

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) -> MeetingBrief {
        eventIDs.append(event.id)
        return standingBrief(for: event)
    }
}

private actor PreemptedStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief {
        callCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        guard callCount == 1 else { return standingBrief(for: event) }
        do {
            try await Task.sleep(for: .seconds(30))
            return standingBrief(for: event)
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
}

private struct AlwaysFailingStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) throws -> MeetingBrief {
        throw StandingSupervisorTestError.failed
    }
}

private enum StandingSupervisorTestError: Error {
    case failed
}

private actor StandingReconciliationCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private func standingBrief(for event: UpcomingEvent) -> MeetingBrief {
    MeetingBrief(
        event: event,
        related: [],
        openItems: [],
        whatToKnow: [])
}
