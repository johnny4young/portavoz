import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Appends one reminder-delivery fact and updates its bounded current
    /// projection atomically. Only confirmed commitments with the exact current
    /// due-date fence may start or continue an active delivery cycle.
    public func applyCommitmentReminderTransition(
        _ transition: CommitmentReminderTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentReminderEventID = CommitmentReminderEventID(),
        at proposedDate: Date = Date()
    ) async throws -> CommitmentReminderState {
        try await database.write { database in
            let commitment = try Self.liveCommitment(
                commitmentID,
                in: database)
            let previous = try CommitmentReminderStateRecord.fetchOne(
                database,
                key: commitmentID.rawValue.uuidString)?.state
            let requested = Self.canonicalCommitmentDate(proposedDate)
            let timestamp = previous.map { state in
                requested > state.updatedAt
                    ? requested
                    : state.updatedAt.addingTimeInterval(0.001)
            } ?? requested
            let canonicalTransition = Self.canonicalReminderTransition(transition)
            try Self.validateReminderCommitmentFence(
                commitment,
                previous: previous,
                transition: canonicalTransition)
            let event = try CommitmentReminderPolicy.event(
                id: eventID,
                commitmentID: commitmentID,
                previousState: previous,
                transition: canonicalTransition,
                occurredAt: timestamp)
            do {
                let state = try CommitmentReminderPolicy.applying(
                    event,
                    to: previous)
                try CommitmentReminderEventRecord(event).insert(database)
                try CommitmentReminderStateRecord(state).save(database)
                return state
            } catch let error as CommitmentReminderValidationError {
                throw StorageError.invalidCommitment(String(describing: error))
            }
        }
    }

    public func commitmentReminderState(
        for commitmentID: CommitmentID
    ) async throws -> CommitmentReminderState? {
        try await database.read { database in
            try CommitmentReminderStateRecord.fetchOne(
                database,
                key: commitmentID.rawValue.uuidString)?.state
        }
    }

    public func commitmentReminderHistory(
        for commitmentID: CommitmentID
    ) async throws -> [CommitmentReminderEvent] {
        try await database.read { database in
            try CommitmentReminderEventRecord
                .filter(Column("commitmentID") == commitmentID.rawValue.uuidString)
                .order(Column("occurredAt"), Column("id"))
                .fetchAll(database)
                .map { try $0.event }
        }
    }
}

private extension MeetingStore {
    static func liveCommitment(
        _ id: CommitmentID,
        in database: Database
    ) throws -> Commitment {
        guard let record = try CommitmentRecord.fetchOne(
            database,
            key: id.rawValue.uuidString),
              record.deletedAt == nil
        else {
            throw StorageError.invalidCommitment(
                "reminder commitment is unavailable")
        }
        return try record.commitment
    }

    static func canonicalReminderTransition(
        _ transition: CommitmentReminderTransition
    ) -> CommitmentReminderTransition {
        switch transition {
        case .schedule(let scheduledFor, let sourceDueAt):
            .schedule(
                scheduledFor: canonicalCommitmentDate(scheduledFor),
                sourceDueAt: canonicalCommitmentDate(sourceDueAt))
        case .snooze(let until):
            .snooze(until: canonicalCommitmentDate(until))
        case .present:
            .present
        case .dismiss:
            .dismiss
        case .cancel:
            .cancel
        }
    }

    static func validateReminderCommitmentFence(
        _ commitment: Commitment,
        previous: CommitmentReminderState?,
        transition: CommitmentReminderTransition
    ) throws {
        switch transition {
        case .schedule(_, let sourceDueAt):
            guard commitment.status == .confirmed,
                  commitment.dueAt == sourceDueAt
            else {
                throw StorageError.invalidCommitment(
                    "only a confirmed commitment with its exact due date can be scheduled")
            }
        case .present, .snooze:
            guard commitment.status == .confirmed,
                  let sourceDueAt = previous?.sourceDueAt,
                  commitment.dueAt == sourceDueAt
            else {
                throw StorageError.invalidCommitment(
                    "active reminder no longer matches the confirmed commitment")
            }
        case .dismiss, .cancel:
            break
        }
    }
}
