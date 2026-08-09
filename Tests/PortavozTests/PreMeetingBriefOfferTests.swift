import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class PreMeetingBriefOfferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFailedBriefRemainsRetryableAndSucceededBriefRetires() async throws {
        let store = try MeetingStore.inMemory()
        let event = upcomingEvent()
        let useCase = LoadPreMeetingBriefOffer(store: store)
        let loadedInitial = try await useCase.execute(event)
        let initial = try XCTUnwrap(loadedInitial)

        XCTAssertEqual(
            initial.offerKey,
            PreMeetingBriefSkill.idempotencyKey(forEvent: event.id))
        XCTAssertFalse(initial.offerKey.contains(event.title))

        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version,
            idempotencyKey: initial.offerKey,
            at: now)
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .recoverable,
            at: now)
        let retry = try await useCase.execute(event)
        XCTAssertNotNil(
            retry,
            "only a failed owner may offer its original retry")

        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: true,
            failureCategory: nil,
            at: now)
        let retired = try await useCase.execute(event)
        XCTAssertNil(retired)
    }

    func testPauseDisablementDismissalAndInvalidIdentityFailClosed() async throws {
        let event = upcomingEvent()

        let pausedStore = try MeetingStore.inMemory()
        try await pausedStore.setAllSkillsPaused(true, at: now)
        let paused = try await LoadPreMeetingBriefOffer(
            store: pausedStore).execute(event)
        XCTAssertNil(paused)

        let disabledStore = try MeetingStore.inMemory()
        try await disabledStore.setSkill(
            PreMeetingBriefSkill.id,
            isEnabled: false,
            at: now)
        let disabled = try await LoadPreMeetingBriefOffer(
            store: disabledStore).execute(event)
        XCTAssertNil(disabled)

        let dismissedStore = try MeetingStore.inMemory()
        let loadedOffer = try await LoadPreMeetingBriefOffer(
            store: dismissedStore).execute(event)
        let offer = try XCTUnwrap(loadedOffer)
        let dismissalDate = now
        try await DismissPreMeetingBriefOffer(
            store: dismissedStore,
            now: { dismissalDate }).execute(offer)
        let dismissed = try await LoadPreMeetingBriefOffer(
            store: dismissedStore).execute(event)
        XCTAssertNil(dismissed)

        let invalid = UpcomingEvent(
            id: " \n ",
            title: "Private title",
            startDate: now,
            attendees: [])
        let malformed = try await LoadPreMeetingBriefOffer(
            store: dismissedStore).execute(invalid)
        XCTAssertNil(malformed)

        let oversized = UpcomingEvent(
            id: String(
                repeating: "x",
                count: UpcomingEvent.maximumIdentifierLength + 1),
            title: "Private title",
            startDate: now,
            attendees: [])
        let unbounded = try await LoadPreMeetingBriefOffer(
            store: dismissedStore).execute(oversized)
        XCTAssertNil(unbounded)
        XCTAssertTrue(UpcomingEvent.isValidIdentity(String(
            repeating: "x",
            count: UpcomingEvent.maximumIdentifierLength)))
        XCTAssertFalse(UpcomingEvent.isValidIdentity(String(
            repeating: "é",
            count: UpcomingEvent.maximumIdentifierLength)))
    }

    func testProposalFactoryPinsOpaqueEventAndProposalIdentity() throws {
        let event = upcomingEvent()
        let proposalID = UUID()
        let built = try XCTUnwrap(PreMeetingBriefProposalFactory.proposal(
            proposalID: proposalID,
            eventID: event.id,
            at: now))

        XCTAssertEqual(built.proposal.id, proposalID)
        XCTAssertEqual(built.proposal.arguments, [.text(event.id)])
        XCTAssertEqual(
            built.idempotencyKey,
            PreMeetingBriefSkill.idempotencyKey(forEvent: event.id))
        XCTAssertTrue(built.proposal.arguments.allSatisfy(\.isValid))

        XCTAssertNil(PreMeetingBriefProposalFactory.proposal(
            proposalID: proposalID,
            eventID: " \n ",
            at: now))

        let otherID = UUID()
        for state in [
            SkillExecutionState.proposed,
            .previewed,
            .confirmed,
            .executing,
            .succeeded,
            .dismissed
        ] {
            XCTAssertNil(PreMeetingBriefProposalFactory.durableProposalID(
                requested: proposalID,
                existing: execution(
                    proposalID: otherID,
                    state: state,
                    idempotencyKey: built.idempotencyKey),
                idempotencyKey: built.idempotencyKey))
        }
        XCTAssertEqual(
            PreMeetingBriefProposalFactory.durableProposalID(
                requested: proposalID,
                existing: execution(
                    proposalID: otherID,
                    state: .failed,
                    idempotencyKey: built.idempotencyKey),
                idempotencyKey: built.idempotencyKey),
            otherID)
        XCTAssertEqual(
            PreMeetingBriefProposalFactory.durableProposalID(
                requested: proposalID,
                existing: execution(
                    proposalID: proposalID,
                    state: .succeeded,
                    idempotencyKey: built.idempotencyKey),
                idempotencyKey: built.idempotencyKey),
            proposalID)
        XCTAssertNil(PreMeetingBriefProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: otherID,
                state: .failed,
                idempotencyKey: "wrong-key"),
            idempotencyKey: built.idempotencyKey))
        XCTAssertNil(PreMeetingBriefProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: otherID,
                state: .failed,
                idempotencyKey: built.idempotencyKey,
                skillID: "another-skill"),
            idempotencyKey: built.idempotencyKey))
        XCTAssertNil(PreMeetingBriefProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: otherID,
                state: .failed,
                idempotencyKey: built.idempotencyKey,
                skillVersion: PreMeetingBriefSkill.version + 1),
            idempotencyKey: built.idempotencyKey))
    }

    private func upcomingEvent() -> UpcomingEvent {
        UpcomingEvent(
            id: "opaque-event-42",
            title: "Private planning title",
            startDate: now.addingTimeInterval(900),
            attendees: ["Ana"])
    }

    private func execution(
        proposalID: UUID,
        state: SkillExecutionState,
        idempotencyKey: String,
        skillID: String = PreMeetingBriefSkill.id,
        skillVersion: Int = PreMeetingBriefSkill.version
    ) -> SkillExecutionRecord {
        SkillExecutionRecord(
            proposalID: proposalID,
            skillID: skillID,
            skillVersion: skillVersion,
            idempotencyKey: idempotencyKey,
            state: state,
            attempt: 1,
            updatedAt: now)
    }
}
