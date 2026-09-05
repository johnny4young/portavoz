import Foundation
import PortavozCore

public struct ReminderDismissalRequest: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let scheduledFor: Date
    public let sourceDueAt: Date
    public let deliveredAt: Date
    public let handledAt: Date

    public init(
        commitmentID: CommitmentID,
        scheduledFor: Date,
        sourceDueAt: Date,
        deliveredAt: Date,
        handledAt: Date
    ) {
        self.commitmentID = commitmentID
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
        self.deliveredAt = deliveredAt
        self.handledAt = handledAt
    }
}

public enum ReminderDismissalOutcome: Sendable, Equatable {
    case dismissed
    case ignoredStaleDelivery
}

public enum ReminderDismissalError: Error, Sendable, Equatable {
    case invalidChronology
}

/// Records one exact delivery before making its local reminder terminal. The
/// confirmed commitment and deadline remain authoritative and unchanged.
public struct DismissCommitmentReminder: ApplicationUseCase {
    private let repository: any CommitmentReminderPresentationRepository
    private let presentationEventID: @Sendable () -> CommitmentReminderEventID
    private let dismissalEventID: @Sendable () -> CommitmentReminderEventID

    public init(
        repository: any CommitmentReminderPresentationRepository,
        presentationEventID: @escaping @Sendable () -> CommitmentReminderEventID =
            CommitmentReminderEventID.init,
        dismissalEventID: @escaping @Sendable () -> CommitmentReminderEventID =
            CommitmentReminderEventID.init
    ) {
        self.repository = repository
        self.presentationEventID = presentationEventID
        self.dismissalEventID = dismissalEventID
    }

    public func execute(
        _ request: ReminderDismissalRequest
    ) async throws -> ReminderDismissalOutcome {
        guard request.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              request.sourceDueAt.timeIntervalSinceReferenceDate.isFinite,
              request.deliveredAt.timeIntervalSinceReferenceDate.isFinite,
              request.handledAt.timeIntervalSinceReferenceDate.isFinite,
              request.scheduledFor <= request.deliveredAt,
              request.deliveredAt <= request.handledAt
        else {
            throw ReminderDismissalError.invalidChronology
        }

        let presentation = try await RecordCommitmentReminderPresentation(
            repository: repository,
            eventID: presentationEventID
        ).execute(ReminderPresentationRequest(
            commitmentID: request.commitmentID,
            scheduledFor: request.scheduledFor,
            sourceDueAt: request.sourceDueAt,
            deliveredAt: request.deliveredAt))
        guard presentation != .ignoredStaleDelivery,
              let state = try await repository.commitmentReminderState(
                for: request.commitmentID),
              state.status == .presented,
              state.scheduledFor == request.scheduledFor,
              state.sourceDueAt == request.sourceDueAt
        else {
            return .ignoredStaleDelivery
        }

        _ = try await repository.applyCommitmentReminderTransition(
            .dismiss,
            to: request.commitmentID,
            eventID: dismissalEventID(),
            at: request.handledAt)
        return .dismissed
    }
}
