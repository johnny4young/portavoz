import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class ReminderDraftOfferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSurfaceLoadsBatchOffersAndKeepsSucceededReceiptVisible() async throws {
        let store = try MeetingStore.inMemory()
        let first = commitment(title: "Send the launch notes")
        let second = commitment(title: "Book the review")
        try await saveCommitments([first, second], in: store)
        let secondKey = ReminderDraftSkill.idempotencyKey(for: second.id)
        let secondProposal = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: secondProposal,
            skillID: ReminderDraftSkill.id,
            skillVersion: ReminderDraftSkill.version,
            offerKey: secondKey,
            idempotencyKey: secondKey,
            at: now)
        _ = try await store.beginSkillExecution(
            proposalID: secondProposal,
            at: now)
        _ = try await store.settleSkillExecution(
            proposalID: secondProposal,
            succeeded: true,
            failureCategory: nil,
            at: now)

        let surface = try await LoadReminderDraftSurface(store: store).execute(
            try ReminderDraftSurfaceRequest(commitments: [first, second]))

        XCTAssertEqual(surface.items.map(\.commitmentID), [first.id, second.id])
        XCTAssertNotNil(surface.items[0].offer)
        XCTAssertNil(surface.items[0].receipt)
        XCTAssertNil(surface.items[1].offer)
        XCTAssertEqual(surface.items[1].receipt?.proposalID, secondProposal)
        XCTAssertEqual(surface.items[1].receipt?.state, .succeeded)
    }

    func testFailedOwnerRetriesButOtherDurableStatesFailClosed() async throws {
        for state in [
            SkillExecutionState.proposed,
            .previewed,
            .confirmed,
            .executing,
            .succeeded,
            .dismissed,
        ] {
            let store = RecordingReminderDraftSurfaceStore(
                executionState: state)
            let surface = try await LoadReminderDraftSurface(store: store).execute(
                try ReminderDraftSurfaceRequest(
                    commitments: [commitment(title: "Ship it")]))
            let item = try XCTUnwrap(surface.items.first)
            XCTAssertNil(item.offer, "\(state) must not be proposed again")
            XCTAssertEqual(item.receipt?.state, state)
        }

        let failedStore = RecordingReminderDraftSurfaceStore(
            executionState: .failed)
        let surface = try await LoadReminderDraftSurface(store: failedStore).execute(
            try ReminderDraftSurfaceRequest(
                commitments: [commitment(title: "Retry it")]))
        let failed = try XCTUnwrap(surface.items.first)
        XCTAssertEqual(failed.offer?.isRetry, true)
        XCTAssertEqual(failed.receipt?.state, .failed)
    }

    func testPauseDisablementDismissalAndNonConfirmedWorkHideOnlyTheOffer() async throws {
        let confirmed = commitment(title: "Confirm me")
        let done = commitment(title: "Already done", status: .done)

        for store in [
            RecordingReminderDraftSurfaceStore(isPaused: true),
            RecordingReminderDraftSurfaceStore(isEnabled: false),
            RecordingReminderDraftSurfaceStore(isDismissed: true),
        ] {
            let surface = try await LoadReminderDraftSurface(store: store).execute(
                try ReminderDraftSurfaceRequest(commitments: [confirmed]))
            XCTAssertNil(surface.items.first?.offer)
        }

        let active = RecordingReminderDraftSurfaceStore()
        let surface = try await LoadReminderDraftSurface(store: active).execute(
            try ReminderDraftSurfaceRequest(commitments: [confirmed, done]))
        XCTAssertEqual(surface.items.count, 1)
        XCTAssertEqual(surface.items.first?.commitmentID, confirmed.id)
    }

    func testSurfaceUsesOneBoundedBatchExecutionRead() async throws {
        let commitments = (0..<ReminderDraftSurfaceRequest.maximumCommitmentCount)
            .map { commitment(title: "Commitment \($0)") }
        let store = RecordingReminderDraftSurfaceStore()

        let surface = try await LoadReminderDraftSurface(store: store).execute(
            try ReminderDraftSurfaceRequest(commitments: commitments))

        XCTAssertEqual(surface.items.count, commitments.count)
        XCTAssertEqual(store.executionKeyBatches.count, 1)
        XCTAssertEqual(
            store.executionKeyBatches[0].count,
            ReminderDraftSurfaceRequest.maximumCommitmentCount)
        XCTAssertThrowsError(try ReminderDraftSurfaceRequest(
            commitments: commitments + [commitment(title: "Too many")]))
        XCTAssertThrowsError(try ReminderDraftSurfaceRequest(
            commitments: [commitments[0], commitments[0]]))
    }

    func testProposalFactoryPinsExactDraftAndDurableRetryIdentity() throws {
        let dueAt = now.addingTimeInterval(3_600)
        let subject = commitment(
            title: "  Send the signed package  ",
            dueAt: dueAt)
        let offer = try XCTUnwrap(ReminderDraftOffer(commitment: subject))
        let proposalID = UUID()
        let built = try XCTUnwrap(ReminderDraftProposalFactory.proposal(
            proposalID: proposalID,
            offer: offer,
            at: now))

        XCTAssertEqual(built.proposal.id, proposalID)
        XCTAssertEqual(built.proposal.arguments, [
            .text("Send the signed package"),
            .date(dueAt),
            .commitment(subject.id),
        ])
        XCTAssertEqual(built.idempotencyKey, offer.offerKey)
        XCTAssertEqual(offer.draft, ReminderDraft(
            title: "Send the signed package",
            dueAt: dueAt,
            commitmentID: subject.id))

        let retryOwner = UUID()
        XCTAssertEqual(ReminderDraftProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: retryOwner,
                state: .failed,
                idempotencyKey: offer.offerKey),
            idempotencyKey: offer.offerKey), retryOwner)
        XCTAssertNil(ReminderDraftProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: retryOwner,
                state: .succeeded,
                idempotencyKey: offer.offerKey),
            idempotencyKey: offer.offerKey))
        XCTAssertNil(ReminderDraftProposalFactory.durableProposalID(
            requested: proposalID,
            existing: execution(
                proposalID: retryOwner,
                state: .failed,
                idempotencyKey: offer.offerKey,
                skillID: "another-skill"),
            idempotencyKey: offer.offerKey))
    }

    private func commitment(
        title: String,
        status: CommitmentStatus = .confirmed,
        dueAt: Date? = nil
    ) -> Commitment {
        Commitment(
            title: title,
            status: status,
            assignee: .me,
            dueAt: dueAt,
            createdAt: now)
    }

    private func execution(
        proposalID: UUID,
        state: SkillExecutionState,
        idempotencyKey: String,
        skillID: String = ReminderDraftSkill.id
    ) -> SkillExecutionRecord {
        SkillExecutionRecord(
            proposalID: proposalID,
            skillID: skillID,
            skillVersion: ReminderDraftSkill.version,
            idempotencyKey: idempotencyKey,
            state: state,
            attempt: 1,
            updatedAt: now)
    }

    private func saveCommitments(
        _ commitments: [Commitment],
        in store: MeetingStore
    ) async throws {
        try await store.database.write { database in
            for commitment in commitments {
                try database.execute(
                    sql: """
                        INSERT INTO commitment (
                            id, canonicalPersonID, title, status, dueAt,
                            createdAt, updatedAt, deletedAt
                        ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        commitment.id.rawValue.uuidString,
                        commitment.title,
                        commitment.status.rawValue,
                        commitment.dueAt,
                        commitment.createdAt,
                        commitment.updatedAt,
                        commitment.deletedAt
                    ])
            }
        }
    }
}

private final class RecordingReminderDraftSurfaceStore:
    ReminderDraftSurfaceStore,
    @unchecked Sendable
{
    let isPaused: Bool
    let isEnabled: Bool
    let isDismissed: Bool
    let executionState: SkillExecutionState?
    var executionKeyBatches: [[String]] = []

    init(
        isPaused: Bool = false,
        isEnabled: Bool = true,
        isDismissed: Bool = false,
        executionState: SkillExecutionState? = nil
    ) {
        self.isPaused = isPaused
        self.isEnabled = isEnabled
        self.isDismissed = isDismissed
        self.executionState = executionState
    }

    func skillExecutionPolicy() -> SkillExecutionPolicy {
        SkillExecutionPolicy(
            isPaused: isPaused,
            disabledSkillIDs: isEnabled ? [] : [ReminderDraftSkill.id])
    }

    func dismissedSkillOffers(offerKeys: [String]) -> Set<String> {
        isDismissed ? Set(offerKeys) : []
    }

    func skillExecutions(
        idempotencyKeys: [String]
    ) -> [SkillExecutionRecord] {
        executionKeyBatches.append(idempotencyKeys)
        guard let executionState, let key = idempotencyKeys.first else { return [] }
        return [SkillExecutionRecord(
            proposalID: UUID(),
            skillID: ReminderDraftSkill.id,
            skillVersion: ReminderDraftSkill.version,
            idempotencyKey: key,
            state: executionState,
            attempt: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
    }

    func dismissSkillOffer(
        offerKey _: String,
        skillID _: String,
        at _: Date
    ) {}

    func reconcileSkillOffers(
        candidateOfferKeys _: [String],
        active _: [SkillOfferRegistration]
    ) {}
}
