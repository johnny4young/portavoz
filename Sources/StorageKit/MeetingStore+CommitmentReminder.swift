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
            let commitment = try Self.persistedCommitment(
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

    /// Replaces one active stale schedule with the commitment's new exact due
    /// fence. Cancel and schedule remain separate immutable facts, while the
    /// projected state changes only if both append successfully.
    public func replaceCommitmentReminderSchedule(
        scheduledFor: Date,
        sourceDueAt: Date,
        commitmentID: CommitmentID,
        cancellationEventID: CommitmentReminderEventID = CommitmentReminderEventID(),
        scheduleEventID: CommitmentReminderEventID = CommitmentReminderEventID(),
        at proposedDate: Date = Date()
    ) async throws -> CommitmentReminderState {
        try await database.write { database in
            let commitment = try Self.persistedCommitment(
                commitmentID,
                in: database)
            guard let previous = try CommitmentReminderStateRecord.fetchOne(
                database,
                key: commitmentID.rawValue.uuidString)?.state,
                  previous.status == .scheduled || previous.status == .presented
            else {
                throw StorageError.invalidCommitment(
                    "only an active reminder schedule can be replaced")
            }

            let requested = Self.canonicalCommitmentDate(proposedDate)
            let cancellationDate = requested > previous.updatedAt
                ? requested
                : previous.updatedAt.addingTimeInterval(0.001)
            let scheduleDate = cancellationDate.addingTimeInterval(0.001)
            let canonicalScheduledFor = Self.canonicalCommitmentDate(scheduledFor)
            let canonicalSourceDueAt = Self.canonicalCommitmentDate(sourceDueAt)

            let cancellation = try CommitmentReminderPolicy.event(
                id: cancellationEventID,
                commitmentID: commitmentID,
                previousState: previous,
                transition: .cancel,
                occurredAt: cancellationDate)
            let cancelled = try CommitmentReminderPolicy.applying(
                cancellation,
                to: previous)
            try Self.validateReminderCommitmentFence(
                commitment,
                previous: cancelled,
                transition: .schedule(
                    scheduledFor: canonicalScheduledFor,
                    sourceDueAt: canonicalSourceDueAt))
            let replacement = try CommitmentReminderPolicy.event(
                id: scheduleEventID,
                commitmentID: commitmentID,
                previousState: cancelled,
                transition: .schedule(
                    scheduledFor: canonicalScheduledFor,
                    sourceDueAt: canonicalSourceDueAt),
                occurredAt: scheduleDate)
            do {
                let state = try CommitmentReminderPolicy.applying(
                    replacement,
                    to: cancelled)
                try CommitmentReminderEventRecord(cancellation).insert(database)
                try CommitmentReminderEventRecord(replacement).insert(database)
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

    /// Reads every commitment that can require a scheduler upsert or an active
    /// delivery cancellation. The query is bounded and reports the complete
    /// count so application policy can refuse a partial reconciliation.
    public func commitmentReminderReconciliationPage(
        _ query: CommitmentReminderReconciliationQuery
    ) async throws -> CommitmentReminderReconciliationPage {
        try await database.read { database in
            let roots = try CommitmentReminderReconciliationRoot.fetchAll(
                database,
                sql: """
                    SELECT commitment.id,
                           commitment.assigneeKind,
                           commitment.canonicalPersonID,
                           commitment.title,
                           commitment.status,
                           commitment.dueAt,
                           commitment.createdAt,
                           commitment.updatedAt,
                           commitment.deletedAt,
                           COUNT(*) OVER () AS totalCount
                    FROM commitment
                    LEFT JOIN commitmentReminderState reminder
                      ON reminder.commitmentID = commitment.id
                    WHERE (
                        commitment.deletedAt IS NULL
                        AND commitment.status = 'confirmed'
                        AND commitment.dueAt IS NOT NULL
                        AND reminder.commitmentID IS NULL
                    ) OR reminder.status IN ('scheduled', 'presented')
                    ORDER BY commitment.updatedAt ASC, commitment.id ASC
                    LIMIT ?
                    """,
                arguments: [query.itemLimit])
            guard !roots.isEmpty else {
                return CommitmentReminderReconciliationPage(
                    items: [],
                    totalCount: 0)
            }

            let commitmentKeys = roots.map(\.id)
            let states = try CommitmentReminderStateRecord
                .filter(commitmentKeys.contains(Column("commitmentID")))
                .fetchAll(database)
                .map { try $0.state }
            let stateByCommitment = Dictionary(
                uniqueKeysWithValues: states.map { ($0.commitmentID, $0) })
            let items = try roots.map { root in
                let commitment = try root.commitment
                return CommitmentReminderReconciliationItem(
                    commitment: commitment,
                    reminder: stateByCommitment[commitment.id])
            }
            return CommitmentReminderReconciliationPage(
                items: items,
                totalCount: roots[0].totalCount)
        }
    }
}

private extension MeetingStore {
    static func persistedCommitment(
        _ id: CommitmentID,
        in database: Database
    ) throws -> Commitment {
        guard let record = try CommitmentRecord.fetchOne(
            database,
            key: id.rawValue.uuidString)
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
            guard commitment.deletedAt == nil,
                  commitment.status == .confirmed,
                  commitment.dueAt == sourceDueAt
            else {
                throw StorageError.invalidCommitment(
                    "only a confirmed commitment with its exact due date can be scheduled")
            }
        case .present, .snooze:
            guard commitment.deletedAt == nil,
                  commitment.status == .confirmed,
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

private struct CommitmentReminderReconciliationRoot: Decodable, FetchableRecord {
    let id: String
    let assigneeKind: String
    let canonicalPersonID: String?
    let title: String
    let status: String
    let dueAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let totalCount: Int

    var commitment: Commitment {
        get throws {
            guard let status = CommitmentStatus(rawValue: status),
                  let assigneeKind = CommitmentAssigneeKind(rawValue: assigneeKind),
                  let assignee = CommitmentAssignee(
                      kind: assigneeKind,
                      canonicalPersonID: try PersistedIdentity.optional(
                          canonicalPersonID,
                          table: CommitmentRecord.databaseTableName,
                          column: "canonicalPersonID"
                      ).map(PersonID.init(rawValue:)))
            else {
                throw StorageError.invalidPersistedValue(
                    table: CommitmentRecord.databaseTableName,
                    column: "assigneeKind",
                    value: self.assigneeKind)
            }
            return Commitment(
                id: CommitmentID(rawValue: try PersistedIdentity.required(
                    id,
                    table: CommitmentRecord.databaseTableName,
                    column: "id")),
                title: title,
                status: status,
                assignee: assignee,
                dueAt: dueAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt)
        }
    }
}
