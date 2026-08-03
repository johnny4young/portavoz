import Foundation
import PortavozCore

public struct ReminderSnoozeRequest: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let scheduledFor: Date
    public let sourceDueAt: Date
    public let deliveredAt: Date
    public let handledAt: Date
    public let snoozeUntil: Date

    public init(
        commitmentID: CommitmentID,
        scheduledFor: Date,
        sourceDueAt: Date,
        deliveredAt: Date,
        handledAt: Date,
        snoozeUntil: Date
    ) {
        self.commitmentID = commitmentID
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
        self.deliveredAt = deliveredAt
        self.handledAt = handledAt
        self.snoozeUntil = snoozeUntil
    }
}

public enum ReminderSnoozeOutcome: Sendable, Equatable {
    case snoozed(until: Date)
    case ignoredStaleDelivery
}

public enum ReminderSnoozeError: Error, Sendable, Equatable {
    case invalidChronology
}

/// Records one exact delivery before moving only its local notification time.
/// The confirmed commitment deadline remains authoritative and unchanged.
public struct SnoozeCommitmentReminder: ApplicationUseCase {
    private let repository: any CommitmentReminderPresentationRepository
    private let presentationEventID: @Sendable () -> CommitmentReminderEventID
    private let snoozeEventID: @Sendable () -> CommitmentReminderEventID

    public init(
        repository: any CommitmentReminderPresentationRepository,
        presentationEventID: @escaping @Sendable () -> CommitmentReminderEventID =
            CommitmentReminderEventID.init,
        snoozeEventID: @escaping @Sendable () -> CommitmentReminderEventID =
            CommitmentReminderEventID.init
    ) {
        self.repository = repository
        self.presentationEventID = presentationEventID
        self.snoozeEventID = snoozeEventID
    }

    public func execute(
        _ request: ReminderSnoozeRequest
    ) async throws -> ReminderSnoozeOutcome {
        guard request.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              request.sourceDueAt.timeIntervalSinceReferenceDate.isFinite,
              request.deliveredAt.timeIntervalSinceReferenceDate.isFinite,
              request.handledAt.timeIntervalSinceReferenceDate.isFinite,
              request.snoozeUntil.timeIntervalSinceReferenceDate.isFinite,
              request.scheduledFor <= request.deliveredAt,
              request.deliveredAt <= request.handledAt,
              request.handledAt < request.snoozeUntil
        else {
            throw ReminderSnoozeError.invalidChronology
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

        let snoozed = try await repository.applyCommitmentReminderTransition(
            .snooze(until: request.snoozeUntil),
            to: request.commitmentID,
            eventID: snoozeEventID(),
            at: request.handledAt)
        return .snoozed(until: snoozed.scheduledFor ?? request.snoozeUntil)
    }
}
