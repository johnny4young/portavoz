import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentRadarMutating: Sendable {
    func applyCommitmentTransition(
        _ transition: CommitmentTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentEventID,
        sourceMeetingID: MeetingID?,
        at proposedDate: Date
    ) async throws -> CommitmentContinuityEnvelope
}

extension MeetingStore: CommitmentRadarMutating {}

/// Explicit user-truth changes available from the global confirmed-only Radar.
/// Reminder snooze is deliberately absent: it belongs to a separate reminder
/// history and must never rewrite the commitment's due date.
public enum CommitmentRadarMutation: Sendable, Equatable {
    case complete
    case reopen
    case reschedule(Date?)
}

public struct ManageCommitmentRadarRequest: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let mutation: CommitmentRadarMutation

    public init(
        commitmentID: CommitmentID,
        mutation: CommitmentRadarMutation
    ) {
        self.commitmentID = commitmentID
        self.mutation = mutation
    }
}

/// Applies one Radar action through the append-only continuity transaction.
/// Presentation cannot fabricate events, attach a source meeting, or choose a
/// timestamp; StorageKit remains the projection and lifecycle authority.
public struct ManageCommitmentRadar: ApplicationUseCase {
    private let repository: any CommitmentRadarMutating
    private let now: @Sendable () -> Date
    private let makeEventID: @Sendable () -> CommitmentEventID

    public init(
        repository: any CommitmentRadarMutating,
        now: @escaping @Sendable () -> Date = Date.init,
        makeEventID: @escaping @Sendable () -> CommitmentEventID = CommitmentEventID.init
    ) {
        self.repository = repository
        self.now = now
        self.makeEventID = makeEventID
    }

    public func execute(
        _ request: ManageCommitmentRadarRequest
    ) async throws -> CommitmentContinuityEnvelope {
        try await repository.applyCommitmentTransition(
            transition(for: request.mutation),
            to: request.commitmentID,
            eventID: makeEventID(),
            sourceMeetingID: nil,
            at: now())
    }

    private func transition(
        for mutation: CommitmentRadarMutation
    ) -> CommitmentTransition {
        switch mutation {
        case .complete:
            .complete
        case .reopen:
            .reopen
        case .reschedule(let dueAt):
            .reschedule(dueAt)
        }
    }
}
