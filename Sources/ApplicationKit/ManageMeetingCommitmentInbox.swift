import Foundation
import PortavozCore

/// Narrow write port for the explicit commitment-admission boundary.
/// Generated candidates remain read-model values; only confirmed truth or
/// reversible source treatment crosses this protocol.
public protocol MeetingCommitmentReviewRepository: Sendable {
    func confirmCommitment(
        _ confirmation: CommitmentConfirmation,
        at date: Date
    ) async throws -> CommitmentContinuityEnvelope

    func linkCommitmentSource(
        _ confirmation: CommitmentLinkConfirmation,
        at date: Date
    ) async throws -> CommitmentContinuityEnvelope

    func setCommitmentReviewDecision(
        _ disposition: CommitmentReviewDisposition?,
        for actionItemID: UUID,
        meetingID: MeetingID,
        revisitAt: Date?,
        at date: Date
    ) async throws
}

public struct ConfirmMeetingCommitmentRequest: Sendable, Equatable {
    public let meetingID: MeetingID
    public let actionItemID: UUID
    public let title: String
    public let assignee: CommitmentAssignee
    public let dueAt: Date?

    public init(
        meetingID: MeetingID,
        actionItemID: UUID,
        title: String,
        assignee: CommitmentAssignee = .unassigned,
        dueAt: Date? = nil
    ) {
        self.meetingID = meetingID
        self.actionItemID = actionItemID
        self.title = title
        self.assignee = assignee
        self.dueAt = dueAt
    }

    public init(
        meetingID: MeetingID,
        actionItemID: UUID,
        title: String,
        canonicalPersonID: PersonID?,
        dueAt: Date? = nil
    ) {
        self.init(
            meetingID: meetingID,
            actionItemID: actionItemID,
            title: title,
            assignee: canonicalPersonID.map(CommitmentAssignee.person) ?? .unassigned,
            dueAt: dueAt)
    }

    public var canonicalPersonID: PersonID? { assignee.canonicalPersonID }
}

public struct LinkMeetingCommitmentRequest: Sendable, Equatable {
    public let meetingID: MeetingID
    public let actionItemID: UUID
    public let commitmentID: CommitmentID

    public init(
        meetingID: MeetingID,
        actionItemID: UUID,
        commitmentID: CommitmentID
    ) {
        self.meetingID = meetingID
        self.actionItemID = actionItemID
        self.commitmentID = commitmentID
    }
}

public enum ReviewMeetingCommitmentRequest: Sendable, Equatable {
    case dismiss(meetingID: MeetingID, actionItemID: UUID)
    case deferUntil(meetingID: MeetingID, actionItemID: UUID, revisitAt: Date)
    case restore(meetingID: MeetingID, actionItemID: UUID)
}

public enum ManageMeetingCommitmentInboxRequest: Sendable, Equatable {
    case confirm(ConfirmMeetingCommitmentRequest)
    case link(LinkMeetingCommitmentRequest)
    case review(ReviewMeetingCommitmentRequest)
}

public enum ManageMeetingCommitmentInboxResult: Sendable, Equatable {
    case confirmed(Commitment)
    case linked(Commitment)
    case reviewed
}

public enum ManageMeetingCommitmentInboxError: Error, Equatable, LocalizedError, Sendable {
    case emptyTitle
    case invalidRevisitDate

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "A confirmed commitment needs a title."
        case .invalidRevisitDate:
            "Choose a future date to review this commitment."
        }
    }
}

/// Owns the explicit transition from generated ActionItem to confirmed truth,
/// plus reversible dismiss/defer treatment that stays attached to the source.
public struct ManageMeetingCommitmentInbox: ApplicationUseCase {
    private let repository: any MeetingCommitmentReviewRepository
    private let now: @Sendable () -> Date

    public init(
        repository: any MeetingCommitmentReviewRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    public func execute(
        _ request: ManageMeetingCommitmentInboxRequest
    ) async throws -> ManageMeetingCommitmentInboxResult {
        switch request {
        case .confirm(let confirmation):
            return .confirmed(try await confirm(confirmation))
        case .link(let linkRequest):
            return .linked(try await link(linkRequest))
        case .review(let reviewRequest):
            try await review(reviewRequest)
            return .reviewed
        }
    }

    public func confirm(
        _ request: ConfirmMeetingCommitmentRequest
    ) async throws -> Commitment {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ManageMeetingCommitmentInboxError.emptyTitle }
        let timestamp = now()
        let envelope = try await repository.confirmCommitment(
            CommitmentConfirmation(
                title: title,
                assignee: request.assignee,
                dueAt: request.dueAt,
                origin: .generatedActionItem(request.actionItemID)),
            at: timestamp)
        return envelope.commitment
    }

    public func link(
        _ request: LinkMeetingCommitmentRequest
    ) async throws -> Commitment {
        let timestamp = now()
        let envelope = try await repository.linkCommitmentSource(
            CommitmentLinkConfirmation(
                commitmentID: request.commitmentID,
                sourceMeetingID: request.meetingID,
                actionItemID: request.actionItemID),
            at: timestamp)
        return envelope.commitment
    }

    public func review(_ request: ReviewMeetingCommitmentRequest) async throws {
        let timestamp = now()
        switch request {
        case .dismiss(let meetingID, let actionItemID):
            try await repository.setCommitmentReviewDecision(
                .dismissed,
                for: actionItemID,
                meetingID: meetingID,
                revisitAt: nil,
                at: timestamp)
        case .deferUntil(let meetingID, let actionItemID, let revisitAt):
            guard revisitAt > timestamp else {
                throw ManageMeetingCommitmentInboxError.invalidRevisitDate
            }
            try await repository.setCommitmentReviewDecision(
                .deferred,
                for: actionItemID,
                meetingID: meetingID,
                revisitAt: revisitAt,
                at: timestamp)
        case .restore(let meetingID, let actionItemID):
            try await repository.setCommitmentReviewDecision(
                nil,
                for: actionItemID,
                meetingID: meetingID,
                revisitAt: nil,
                at: timestamp)
        }
    }
}
