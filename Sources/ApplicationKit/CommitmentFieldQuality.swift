import Foundation
import PortavozCore
import StorageKit

public protocol CommitmentFieldQualityReading: Sendable {
    func commitmentFieldQualityObservations(
        endingAt windowEnd: Date
    ) async throws -> [CommitmentFieldQualityObservation]
}

public protocol CommitmentFieldPresentationRecording: Sendable {
    func recordCommitmentFieldPresentation(
        actionItemID: UUID,
        meetingID: MeetingID,
        observationID: UUID,
        at presentedAt: Date
    ) async throws -> UUID
}

extension MeetingStore: CommitmentFieldQualityReading,
    CommitmentFieldPresentationRecording {}

/// Loads only aggregate, content-free field quality into product composition.
/// Presentation layers never receive the owner tokens or source identities
/// used to calculate the scorecard.
public struct LoadCommitmentFieldQuality: ApplicationUseCase {
    private let repository: any CommitmentFieldQualityReading
    private let now: @Sendable () -> Date

    public init(
        repository: any CommitmentFieldQualityReading,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    public func execute(_ request: Void) async throws -> CommitmentFieldQualityScorecard {
        let windowEnd = now()
        let observations = try await repository.commitmentFieldQualityObservations(
            endingAt: windowEnd)
        return try CommitmentFieldQualityEvaluator.evaluate(
            observations,
            endingAt: windowEnd)
    }
}

public struct RecordCommitmentFieldPresentationRequest: Equatable, Sendable {
    public let meetingID: MeetingID
    public let actionItemID: UUID

    public init(meetingID: MeetingID, actionItemID: UUID) {
        self.meetingID = meetingID
        self.actionItemID = actionItemID
    }
}

/// Owns identity and time for a card that reached the user's review surface.
/// Storage remains idempotent, so view retries cannot move the first-seen time.
public struct RecordCommitmentFieldPresentation: ApplicationUseCase {
    private let repository: any CommitmentFieldPresentationRecording
    private let now: @Sendable () -> Date
    private let makeObservationID: @Sendable () -> UUID

    public init(
        repository: any CommitmentFieldPresentationRecording,
        now: @escaping @Sendable () -> Date = Date.init,
        makeObservationID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.now = now
        self.makeObservationID = makeObservationID
    }

    @discardableResult
    public func execute(
        _ request: RecordCommitmentFieldPresentationRequest
    ) async throws -> UUID {
        try await repository.recordCommitmentFieldPresentation(
            actionItemID: request.actionItemID,
            meetingID: request.meetingID,
            observationID: makeObservationID(),
            at: now())
    }
}
