import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class ManageMeetingCommitmentInboxTests: XCTestCase {
    func testConfirmationTrimsTitleAndPreservesExplicitOwnerDeadlineAndSource() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = MeetingID()
        let actionItemID = UUID()
        let personID = PersonID()
        let dueAt = now.addingTimeInterval(86_400)
        let repository = CommitmentReviewRepositoryFake()
        let useCase = ManageMeetingCommitmentInbox(repository: repository, now: { now })

        let commitment = try await useCase.confirm(ConfirmMeetingCommitmentRequest(
            meetingID: meetingID,
            actionItemID: actionItemID,
            title: "  Prepare the rollout  ",
            canonicalPersonID: personID,
            dueAt: dueAt))

        let calls = await repository.confirmations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.date, now)
        XCTAssertEqual(calls.first?.confirmation.title, "Prepare the rollout")
        XCTAssertEqual(calls.first?.confirmation.canonicalPersonID, personID)
        XCTAssertEqual(calls.first?.confirmation.dueAt, dueAt)
        guard case .generatedActionItem(actionItemID) = calls.first?.confirmation.origin else {
            return XCTFail("confirmation must preserve the canonical generated source")
        }
        XCTAssertEqual(commitment.title, "Prepare the rollout")
        XCTAssertEqual(commitment.canonicalPersonID, personID)
        XCTAssertEqual(commitment.dueAt, dueAt)
    }

    func testReviewTreatmentsStaySourceBoundAndRejectPastDeferral() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = MeetingID()
        let actionItemID = UUID()
        let repository = CommitmentReviewRepositoryFake()
        let useCase = ManageMeetingCommitmentInbox(repository: repository, now: { now })

        try await useCase.review(.dismiss(
            meetingID: meetingID,
            actionItemID: actionItemID))
        try await useCase.review(.restore(
            meetingID: meetingID,
            actionItemID: actionItemID))
        let revisitAt = now.addingTimeInterval(7 * 86_400)
        try await useCase.review(.deferUntil(
            meetingID: meetingID,
            actionItemID: actionItemID,
            revisitAt: revisitAt))

        let calls = await repository.decisions
        XCTAssertEqual(calls.map(\.disposition), [.dismissed, nil, .deferred])
        XCTAssertEqual(calls.map(\.actionItemID), [actionItemID, actionItemID, actionItemID])
        XCTAssertEqual(calls.map(\.meetingID), [meetingID, meetingID, meetingID])
        XCTAssertEqual(calls.map(\.revisitAt), [nil, nil, revisitAt])
        XCTAssertEqual(calls.map(\.date), [now, now, now])

        do {
            try await useCase.review(.deferUntil(
                meetingID: meetingID,
                actionItemID: actionItemID,
                revisitAt: now))
            XCTFail("a non-future review date must fail before persistence")
        } catch {
            XCTAssertEqual(
                error as? ManageMeetingCommitmentInboxError,
                .invalidRevisitDate)
        }
        let recordedDecisions = await repository.decisions
        XCTAssertEqual(recordedDecisions.count, 3)
    }

    func testConfirmationPreservesExplicitSelfAssignment() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CommitmentReviewRepositoryFake()
        let useCase = ManageMeetingCommitmentInbox(repository: repository, now: { now })

        let commitment = try await useCase.confirm(ConfirmMeetingCommitmentRequest(
            meetingID: MeetingID(),
            actionItemID: UUID(),
            title: "Send the report",
            assignee: .me))

        let calls = await repository.confirmations
        XCTAssertEqual(calls.first?.confirmation.assignee, .me)
        XCTAssertEqual(commitment.assignee, .me)
    }

    func testLinkPreservesExpectedSourceAndExistingCommitmentIdentity() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meetingID = MeetingID()
        let actionItemID = UUID()
        let commitmentID = CommitmentID()
        let repository = CommitmentReviewRepositoryFake()
        let useCase = ManageMeetingCommitmentInbox(repository: repository, now: { now })

        let commitment = try await useCase.link(LinkMeetingCommitmentRequest(
            meetingID: meetingID,
            actionItemID: actionItemID,
            commitmentID: commitmentID))

        let calls = await repository.links
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.date, now)
        XCTAssertEqual(calls.first?.confirmation.commitmentID, commitmentID)
        XCTAssertEqual(calls.first?.confirmation.sourceMeetingID, meetingID)
        XCTAssertEqual(calls.first?.confirmation.actionItemID, actionItemID)
        XCTAssertEqual(commitment.id, commitmentID)
    }
}

private actor CommitmentReviewRepositoryFake: MeetingCommitmentReviewRepository {
    struct ConfirmationCall: Sendable {
        let confirmation: CommitmentConfirmation
        let date: Date
    }

    struct DecisionCall: Sendable {
        let disposition: CommitmentReviewDisposition?
        let actionItemID: UUID
        let meetingID: MeetingID
        let revisitAt: Date?
        let date: Date
    }

    struct LinkCall: Sendable {
        let confirmation: CommitmentLinkConfirmation
        let date: Date
    }

    private(set) var confirmations: [ConfirmationCall] = []
    private(set) var links: [LinkCall] = []
    private(set) var decisions: [DecisionCall] = []

    func confirmCommitment(
        _ confirmation: CommitmentConfirmation,
        at date: Date
    ) throws -> CommitmentContinuityEnvelope {
        confirmations.append(ConfirmationCall(confirmation: confirmation, date: date))
        let event = CommitmentEvent(
            id: confirmation.eventID,
            commitmentID: confirmation.commitmentID,
            kind: .confirm,
            assignee: confirmation.assignee,
            dueAt: confirmation.dueAt,
            occurredAt: date)
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: confirmation.commitmentID,
            title: confirmation.title,
            events: [event])
        let source = CommitmentSource(
            id: confirmation.sourceID,
            commitmentID: confirmation.commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: date)
        return try CommitmentContinuityEnvelope(
            commitment: commitment,
            sources: [source],
            events: [event])
    }

    func linkCommitmentSource(
        _ confirmation: CommitmentLinkConfirmation,
        at date: Date
    ) throws -> CommitmentContinuityEnvelope {
        links.append(LinkCall(confirmation: confirmation, date: date))
        let event = CommitmentEvent(
            commitmentID: confirmation.commitmentID,
            kind: .confirm,
            assignee: .unassigned,
            occurredAt: date.addingTimeInterval(-1))
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: confirmation.commitmentID,
            title: "Existing commitment",
            events: [event])
        let initial = CommitmentSource(
            commitmentID: confirmation.commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: date.addingTimeInterval(-1))
        let linked = CommitmentSource(
            id: confirmation.sourceID,
            commitmentID: confirmation.commitmentID,
            kind: .manual,
            meetingID: confirmation.sourceMeetingID,
            firstSeenAt: date)
        return try CommitmentContinuityEnvelope(
            commitment: commitment,
            sources: [initial, linked],
            events: [event])
    }

    func setCommitmentReviewDecision(
        _ disposition: CommitmentReviewDisposition?,
        for actionItemID: UUID,
        meetingID: MeetingID,
        revisitAt: Date?,
        at date: Date
    ) {
        decisions.append(DecisionCall(
            disposition: disposition,
            actionItemID: actionItemID,
            meetingID: meetingID,
            revisitAt: revisitAt,
            date: date))
    }
}
