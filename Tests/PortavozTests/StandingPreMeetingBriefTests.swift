import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class StandingPreMeetingBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testStandingDefinitionAdmitsOnlyReversibleLocalWorkWithoutConfirmation() {
        let definition = PreMeetingBriefSkill.standingRuleDefinition
        XCTAssertEqual(definition.confirmationPolicy, .standingRule)
        XCTAssertTrue(definition.isValid)
        XCTAssertTrue(definition.isReversible)
        XCTAssertFalse(definition.declaresExternalEffect)
        let event = upcomingEvent()
        let proposal = SkillProposal(
            definition: definition,
            subject: .calendarEvent(event.id),
            requestedCapabilities: definition.capabilities,
            requestedInputDataClasses: definition.inputDataClasses,
            arguments: [.text(event.id)],
            proposedAt: now)

        XCTAssertEqual(
            SkillAdmissionPolicy.admit(
                proposal,
                isConfirmedByUser: false,
                egressIsPermitted: false,
                at: now),
            .admitted)
    }

    func testExactEventProducesOneDurableLocalArtifact() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let expectedBrief = brief(for: event)
        let resolver = StandingEventResolver(event: event)
        let proposalID = UUID()
        let useCase = makeUseCase(
            store: store,
            preparer: StandingBriefPreparer(result: expectedBrief),
            resolver: resolver,
            proposalID: proposalID)

        let outcome = try await useCase.execute((rule, event))

        XCTAssertEqual(outcome, .prepared(proposalID))
        let occurrence = StandingSkillOccurrence(
            eventID: event.id,
            eventStartAt: event.startDate)
        let key = StandingSkillExecutionIdentity.idempotencyKey(
            ruleID: rule.id,
            occurrence: occurrence)
        let recordValue = try await store.skillExecution(idempotencyKey: key)
        let record = try XCTUnwrap(recordValue)
        XCTAssertEqual(record.state, .succeeded)
    }

    func testSuccessIsAbsentFromPendingAndDecodesExactArtifact() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let expectedBrief = brief(for: event)
        let proposalID = UUID()
        let useCase = makeUseCase(
            store: store,
            preparer: StandingBriefPreparer(result: expectedBrief),
            resolver: StandingEventResolver(event: event),
            proposalID: proposalID)

        let outcome = try await useCase.execute((rule, event))
        XCTAssertEqual(outcome, .prepared(proposalID))
        let pending = try await store.pendingStandingSkillExecutions(limit: 32)
        XCTAssertTrue(pending.isEmpty)
        let artifactValue = try await store.standingSkillArtifact(
            proposalID: proposalID)
        let artifact = try XCTUnwrap(artifactValue)
        XCTAssertEqual(
            try StandingPreMeetingBriefArtifactCodec.decode(artifact),
            expectedBrief)
        let history = try await store.skillExecutionHistory(
            proposalID: proposalID)
        XCTAssertEqual(history.map(\.kind), ["confirm", "begin", "succeed"])
    }

    func testCancellationCancelsNewClaimWithoutArtifact() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let preparer = SuspendedStandingBriefPreparer(result: brief(for: event))
        let proposalID = UUID()
        let useCase = makeUseCase(
            store: store,
            preparer: preparer,
            resolver: StandingEventResolver(event: event),
            proposalID: proposalID,
            timeout: .seconds(10))
        let task = Task { try await useCase.execute((rule, event)) }
        await preparer.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must escape the use case")
        } catch is CancellationError {
            // Expected.
        }

        let auditValue = try await store.skillExecutionAudit(
            proposalID: proposalID)
        let audit = try XCTUnwrap(auditValue)
        XCTAssertEqual(audit.record.state, .dismissed)
        XCTAssertEqual(audit.history.map(\.kind), ["confirm", "cancel"])
        let artifact = try await store.standingSkillArtifact(
            proposalID: proposalID)
        XCTAssertNil(artifact)
    }

    func testTimeoutFailsThenRelaunchResumesSameOwner() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let proposalID = UUID()
        let first = makeUseCase(
            store: store,
            preparer: DelayedStandingBriefPreparer(
                result: brief(for: event),
                delay: .seconds(1)),
            resolver: StandingEventResolver(event: event),
            proposalID: proposalID,
            timeout: .milliseconds(10))

        let firstOutcome = try await first.execute((rule, event))
        XCTAssertEqual(firstOutcome, .failed(proposalID))
        let pending = try await store.pendingStandingSkillExecutions(limit: 32)
        let owner = try XCTUnwrap(pending.first)
        XCTAssertEqual(owner.record.state, .failed)
        XCTAssertEqual(owner.record.attempt, 1)

        let relaunched = makeUseCase(
            store: store,
            preparer: StandingBriefPreparer(result: brief(for: event)),
            resolver: StandingEventResolver(event: event),
            proposalID: UUID())
        let resumed = try await relaunched.resume(owner, event: event)
        XCTAssertEqual(resumed, .prepared(proposalID))
        let history = try await store.skillExecutionHistory(
            proposalID: proposalID)
        XCTAssertEqual(
            history.map { "\($0.kind):\($0.attempt)" },
            [
                "confirm:1", "begin:1", "fail:1",
                "begin:2", "succeed:2"
            ])
    }

    func testMovedEventCancelsClaimAndCannotPublishStaleDraft() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let moved = UpcomingEvent(
            id: event.id,
            title: event.title,
            startDate: event.startDate.addingTimeInterval(600),
            attendees: event.attendees)
        let proposalID = UUID()
        let useCase = makeUseCase(
            store: store,
            preparer: StandingBriefPreparer(result: brief(for: event)),
            resolver: StandingEventResolver(event: moved),
            proposalID: proposalID)

        do {
            _ = try await useCase.execute((rule, event))
            XCTFail("a moved occurrence must invalidate the prepared content")
        } catch let error as StandingPreMeetingBriefError {
            XCTAssertEqual(error, .eventChanged)
        }
        let auditValue = try await store.skillExecutionAudit(
            proposalID: proposalID)
        let audit = try XCTUnwrap(auditValue)
        XCTAssertEqual(audit.record.state, .dismissed)
        XCTAssertEqual(audit.history.map(\.kind), ["confirm", "cancel"])
        let artifact = try await store.standingSkillArtifact(
            proposalID: proposalID)
        XCTAssertNil(artifact)
    }

    func testPauseWinningCompletionRaceLeavesRetryableClaim() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let event = upcomingEvent()
        let proposalID = UUID()
        let preparer = PausingStandingBriefPreparer(
            result: brief(for: event),
            store: store,
            pausedAt: now.addingTimeInterval(1))
        let useCase = makeUseCase(
            store: store,
            preparer: preparer,
            resolver: StandingEventResolver(event: event),
            proposalID: proposalID)

        let outcome = try await useCase.execute((rule, event))
        XCTAssertEqual(outcome, .deferred(.allSkillsPaused))
        let pending = try await store.pendingStandingSkillExecutions(limit: 32)
        XCTAssertEqual(pending.first?.record.state, .confirmed)
        let artifact = try await store.standingSkillArtifact(
            proposalID: proposalID)
        XCTAssertNil(artifact)
    }

    func testOutOfWindowAndOversizedContentFailClosed() async throws {
        let outOfWindowStore = try MeetingStore.inMemory()
        let outOfWindowRule = try await createRule(in: outOfWindowStore)
        let lateEvent = UpcomingEvent(
            id: "later-event",
            title: "Later",
            startDate: now.addingTimeInterval(
                ExecuteStandingPreMeetingBrief.maximumPreparationLeadTime + 1),
            attendees: [])
        let outOfWindow = makeUseCase(
            store: outOfWindowStore,
            preparer: StandingBriefPreparer(result: brief(for: lateEvent)),
            resolver: StandingEventResolver(event: lateEvent),
            proposalID: UUID())
        do {
            _ = try await outOfWindow.execute((outOfWindowRule, lateEvent))
            XCTFail("an event outside the bounded lead window must not claim")
        } catch let error as StandingPreMeetingBriefError {
            XCTAssertEqual(error, .invalidEvent)
        }
        let outOfWindowPending = try await outOfWindowStore
            .pendingStandingSkillExecutions(limit: 32)
        XCTAssertTrue(outOfWindowPending.isEmpty)

        let oversizedStore = try MeetingStore.inMemory()
        let oversizedRule = try await createRule(in: oversizedStore)
        let event = upcomingEvent()
        let oversizedEvent = UpcomingEvent(
            id: event.id,
            title: String(
                repeating: "x",
                count: StandingPreMeetingBriefArtifactCodec
                    .maximumStringUTF8ByteCount + 1),
            startDate: event.startDate,
            attendees: event.attendees)
        let proposalID = UUID()
        let oversized = makeUseCase(
            store: oversizedStore,
            preparer: StandingBriefPreparer(
                result: brief(for: oversizedEvent)),
            resolver: StandingEventResolver(event: oversizedEvent),
            proposalID: proposalID)
        let oversizedOutcome = try await oversized.execute(
            (oversizedRule, oversizedEvent))
        XCTAssertEqual(oversizedOutcome, .failed(proposalID))
        let oversizedArtifact = try await oversizedStore.standingSkillArtifact(
            proposalID: proposalID)
        XCTAssertNil(oversizedArtifact)
    }

    private func makeUseCase(
        store: MeetingStore,
        preparer: any StandingPreMeetingBriefPreparing,
        resolver: any UpcomingEventResolving,
        proposalID: UUID,
        timeout: Duration = .seconds(1)
    ) -> ExecuteStandingPreMeetingBrief {
        let instant = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return ExecuteStandingPreMeetingBrief(
            store: store,
            preparer: preparer,
            events: resolver,
            calendar: calendar,
            timeout: timeout,
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

    private func upcomingEvent() -> UpcomingEvent {
        UpcomingEvent(
            id: "standing-upcoming-event",
            title: "Private planning title",
            startDate: now.addingTimeInterval(30 * 60),
            attendees: ["Ana"])
    }

    private func brief(for event: UpcomingEvent) -> MeetingBrief {
        let meetingID = MeetingID()
        return MeetingBrief(
            event: event,
            related: [MeetingBrief.RelatedMeeting(
                meetingID: meetingID,
                title: "Earlier rollout",
                overview: "Budget approved",
                matchedTerms: ["rollout"],
                snippet: "Approved in the earlier meeting")],
            openItems: [MeetingBrief.OpenItem(
                id: UUID(),
                meetingID: meetingID,
                meetingTitle: "Earlier rollout",
                text: "Send the plan")],
            whatToKnow: [MeetingBrief.KnowPoint(
                id: UUID(),
                text: "The budget was approved.",
                meetingID: meetingID,
                meetingTitle: "Earlier rollout")])
    }
}

private actor StandingEventResolver: UpcomingEventResolving {
    let event: UpcomingEvent?

    init(event: UpcomingEvent?) {
        self.event = event
    }

    func upcomingEvent(matching identifier: String) -> UpcomingEvent? {
        event?.id == identifier ? event : nil
    }
}

private struct StandingBriefPreparer: StandingPreMeetingBriefPreparing {
    let result: MeetingBrief

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) -> MeetingBrief {
        result
    }
}

private struct DelayedStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    let result: MeetingBrief
    let delay: Duration

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief {
        try await Task.sleep(for: delay)
        return result
    }
}

private actor SuspendedStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    let result: MeetingBrief
    private var started = false

    init(result: MeetingBrief) {
        self.result = result
    }

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief {
        started = true
        try await Task.sleep(for: .seconds(10))
        return result
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private struct PausingStandingBriefPreparer:
    StandingPreMeetingBriefPreparing {
    let result: MeetingBrief
    let store: MeetingStore
    let pausedAt: Date

    func prepareStandingPreMeetingBrief(
        for event: UpcomingEvent
    ) async throws -> MeetingBrief {
        try await store.setAllSkillsPaused(true, at: pausedAt)
        return result
    }
}
