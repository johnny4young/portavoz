import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentReminderPresentationRepository: Sendable {
    func commitmentReminderState(
        for commitmentID: CommitmentID
    ) async throws -> CommitmentReminderState?

    func applyCommitmentReminderTransition(
        _ transition: CommitmentReminderTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentReminderEventID,
        at proposedDate: Date
    ) async throws -> CommitmentReminderState
}

extension MeetingStore: CommitmentReminderPresentationRepository {}

public struct ReminderPresentationRequest: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let scheduledFor: Date
    public let sourceDueAt: Date
    public let deliveredAt: Date

    public init(
        commitmentID: CommitmentID,
        scheduledFor: Date,
        sourceDueAt: Date,
        deliveredAt: Date
    ) {
        self.commitmentID = commitmentID
        self.scheduledFor = scheduledFor
        self.sourceDueAt = sourceDueAt
        self.deliveredAt = deliveredAt
    }
}

public enum ReminderPresentationOutcome: Sendable, Equatable {
    case recorded
    case alreadyRecorded
    case ignoredStaleDelivery
}

public enum ReminderPresentationError: Error, Sendable, Equatable {
    case invalidDelivery
}

/// Persists a platform-observed delivery without trusting notification content
/// as commitment truth. Missing, terminal, or replaced reminder identities are
/// stale no-ops so an old Notification Center item can never revive work.
public struct RecordCommitmentReminderPresentation: ApplicationUseCase {
    private let repository: any CommitmentReminderPresentationRepository
    private let eventID: @Sendable () -> CommitmentReminderEventID

    public init(
        repository: any CommitmentReminderPresentationRepository,
        eventID: @escaping @Sendable () -> CommitmentReminderEventID =
            CommitmentReminderEventID.init
    ) {
        self.repository = repository
        self.eventID = eventID
    }

    public func execute(
        _ request: ReminderPresentationRequest
    ) async throws -> ReminderPresentationOutcome {
        guard request.scheduledFor.timeIntervalSinceReferenceDate.isFinite,
              request.sourceDueAt.timeIntervalSinceReferenceDate.isFinite,
              request.deliveredAt.timeIntervalSinceReferenceDate.isFinite,
              request.scheduledFor <= request.deliveredAt
        else {
            throw ReminderPresentationError.invalidDelivery
        }
        guard let state = try await repository.commitmentReminderState(
            for: request.commitmentID),
              state.scheduledFor == request.scheduledFor,
              state.sourceDueAt == request.sourceDueAt
        else {
            return .ignoredStaleDelivery
        }

        switch state.status {
        case .presented:
            return .alreadyRecorded
        case .scheduled:
            do {
                _ = try await repository.applyCommitmentReminderTransition(
                    .present,
                    to: request.commitmentID,
                    eventID: eventID(),
                    at: max(request.deliveredAt, state.updatedAt))
                return .recorded
            } catch {
                guard let recovered = try? await repository.commitmentReminderState(
                    for: request.commitmentID),
                      recovered.status == .presented,
                      recovered.scheduledFor == request.scheduledFor,
                      recovered.sourceDueAt == request.sourceDueAt
                else {
                    throw error
                }
                return .alreadyRecorded
            }
        case .dismissed, .cancelled:
            return .ignoredStaleDelivery
        }
    }
}
