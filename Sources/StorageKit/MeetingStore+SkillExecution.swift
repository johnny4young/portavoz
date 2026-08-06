import Foundation
import GRDB
import PortavozCore

/// What a durable admission attempt concluded. `alreadySettled` is the answer a
/// retry or a relaunch gets: the effect is spoken for, do not run it again.
public enum SkillExecutionAdmission: Equatable, Sendable {
    case admitted(SkillExecutionRecord)
    case alreadySettled(SkillExecutionRecord)
    case rejected(SkillExecutionRejection)
}

public enum SkillExecutionRejection: String, Equatable, Sendable {
    case invalidProposal = "invalid-proposal"
    /// The idempotency key belongs to a different proposal, so admitting this
    /// one would let two proposals claim one effect.
    case idempotencyKeyClaimed = "idempotency-key-claimed"
    case unknownExecution = "unknown-execution"
    case illegalTransition = "illegal-transition"
}

public struct SkillExecutionRecord: Equatable, Sendable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let idempotencyKey: String
    public let state: SkillExecutionState
    public let attempt: Int
    public let updatedAt: Date

    public init(
        proposalID: UUID,
        skillID: String,
        skillVersion: Int,
        idempotencyKey: String,
        state: SkillExecutionState,
        attempt: Int,
        updatedAt: Date
    ) {
        self.proposalID = proposalID
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.attempt = attempt
        self.updatedAt = updatedAt
    }
}

extension MeetingStore {
    /// Records the user's confirmation durably before anything runs.
    ///
    /// This is the idempotency boundary: the effect belongs to one
    /// `idempotencyKey`, and a second confirmation of the same proposal returns
    /// the existing record rather than creating a second claim on it.
    public func confirmSkillExecution(
        proposalID: UUID,
        skillID: String,
        skillVersion: Int,
        idempotencyKey: String,
        at now: Date
    ) async throws -> SkillExecutionAdmission {
        let trimmedSkill = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = idempotencyKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedSkill.isEmpty,
              trimmedSkill == skillID,
              !trimmedKey.isEmpty,
              trimmedKey == idempotencyKey,
              skillVersion >= 1
        else { return .rejected(.invalidProposal) }

        return try await database.write { database in
            if let existing = try Self.skillExecution(proposalID, in: database) {
                guard existing.idempotencyKey == idempotencyKey else {
                    return .rejected(.idempotencyKeyClaimed)
                }
                return .alreadySettled(existing)
            }
            // A different proposal already owns this key.
            let claimed = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM skillExecutionState WHERE idempotencyKey = ?
                    )
                    """,
                arguments: [idempotencyKey]) ?? false
            guard !claimed else { return .rejected(.idempotencyKeyClaimed) }

            let eventID = try Self.appendSkillEvent(
                proposalID: proposalID,
                previousEventID: nil,
                kind: "confirm",
                attempt: 1,
                failureCategory: nil,
                at: now,
                in: database)
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionState (
                        proposalID, skillID, skillVersion, idempotencyKey,
                        state, attempt, latestEventID, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, 'confirmed', 1, ?, ?, ?)
                    """,
                arguments: [
                    proposalID.uuidString, skillID, skillVersion,
                    idempotencyKey, eventID, now, now
                ])
            let record = try Self.skillExecution(proposalID, in: database)
            guard let record else { return .rejected(.unknownExecution) }
            return .admitted(record)
        }
    }

    /// Claims the right to run. Only a `confirmed` or previously `failed`
    /// execution may begin, and a `failed` one increments its attempt so the
    /// event log distinguishes a retry from the original run.
    ///
    /// A `succeeded` execution answers `alreadySettled`: relaunching after a
    /// crash that happened *after* the effect must not repeat it.
    public func beginSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission {
        try await database.write { database in
            guard let existing = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }

            switch existing.state {
            case .succeeded, .dismissed:
                return .alreadySettled(existing)
            case .executing:
                // A previous process died mid-run. The effect may or may not
                // have landed, so the caller must reconcile rather than blindly
                // repeat: this is deliberately not an admission.
                return .alreadySettled(existing)
            case .confirmed, .failed:
                break
            case .proposed, .previewed:
                return .rejected(.illegalTransition)
            }

            let attempt = existing.state == .failed
                ? existing.attempt + 1
                : existing.attempt
            try Self.advanceSkillExecution(
                proposalID: proposalID,
                kind: "begin",
                state: "executing",
                attempt: attempt,
                failureCategory: nil,
                at: now,
                in: database)
            guard let record = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }
            return .admitted(record)
        }
    }

    /// Terminal outcome for the current attempt. `failureCategory` is a typed
    /// category, never a message and never meeting-derived text.
    public func settleSkillExecution(
        proposalID: UUID,
        succeeded: Bool,
        failureCategory: FailureCategory?,
        at now: Date
    ) async throws -> SkillExecutionAdmission {
        try await database.write { database in
            guard let existing = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }
            guard existing.state == .executing else {
                return .rejected(.illegalTransition)
            }
            guard succeeded == (failureCategory == nil) else {
                return .rejected(.illegalTransition)
            }
            try Self.advanceSkillExecution(
                proposalID: proposalID,
                kind: succeeded ? "succeed" : "fail",
                state: succeeded ? "succeeded" : "failed",
                attempt: existing.attempt,
                failureCategory: failureCategory?.rawValue,
                at: now,
                in: database)
            guard let record = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }
            return .admitted(record)
        }
    }

    /// Cancels before an irreversible handoff. An execution that already began
    /// cannot be cancelled: only its outcome can be recorded, because the
    /// effect may already exist.
    public func cancelSkillExecution(
        proposalID: UUID,
        at now: Date
    ) async throws -> SkillExecutionAdmission {
        try await database.write { database in
            guard let existing = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }
            guard existing.state == .confirmed else {
                return .rejected(.illegalTransition)
            }
            try Self.advanceSkillExecution(
                proposalID: proposalID,
                kind: "cancel",
                state: "cancelled",
                attempt: existing.attempt,
                failureCategory: nil,
                at: now,
                in: database)
            guard let record = try Self.skillExecution(proposalID, in: database)
            else { return .rejected(.unknownExecution) }
            return .alreadySettled(record)
        }
    }

    /// The auditable local history of one proposal, oldest first.
    ///
    /// Ordered by insertion, not by `occurredAt`: two transitions can share a
    /// timestamp, and the log is append-only, so insertion order is the causal
    /// order. Ordering by time with an id tiebreak would sort a confirmation
    /// after the run it authorized whenever both landed in the same instant.
    public func skillExecutionHistory(
        proposalID: UUID
    ) async throws -> [SkillExecutionHistoryEntry] {
        try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT kind, attempt, failureCategory, occurredAt
                    FROM skillExecutionEvent
                    WHERE proposalID = ?
                    ORDER BY rowid ASC
                    """,
                arguments: [proposalID.uuidString]
            ).map { row in
                SkillExecutionHistoryEntry(
                    kind: row["kind"],
                    attempt: row["attempt"],
                    failureCategory: (row["failureCategory"] as String?)
                        .flatMap(FailureCategory.init(rawValue:)),
                    occurredAt: row["occurredAt"])
            }
        }
    }

    // MARK: - Internals

    private static func skillExecution(
        _ proposalID: UUID,
        in database: Database
    ) throws -> SkillExecutionRecord? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT proposalID, skillID, skillVersion, idempotencyKey,
                       state, attempt, updatedAt
                FROM skillExecutionState
                WHERE proposalID = ?
                """,
            arguments: [proposalID.uuidString])
        else { return nil }
        let raw: String = row["state"]
        // `cancelled` is the durable spelling of a dismissal that never ran.
        let state: SkillExecutionState = raw == "cancelled"
            ? .dismissed
            : (SkillExecutionState(rawValue: raw) ?? .failed)
        return SkillExecutionRecord(
            proposalID: proposalID,
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            idempotencyKey: row["idempotencyKey"],
            state: state,
            attempt: row["attempt"],
            updatedAt: row["updatedAt"])
    }

    private static func appendSkillEvent(
        proposalID: UUID,
        previousEventID: String?,
        kind: String,
        attempt: Int,
        failureCategory: String?,
        at now: Date,
        in database: Database
    ) throws -> String {
        let eventID = UUID().uuidString
        try database.execute(
            sql: """
                INSERT INTO skillExecutionEvent (
                    id, proposalID, previousEventID, kind, attempt,
                    failureCategory, occurredAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                eventID, proposalID.uuidString, previousEventID, kind,
                attempt, failureCategory, now
            ])
        return eventID
    }

    private static func advanceSkillExecution(
        proposalID: UUID,
        kind: String,
        state: String,
        attempt: Int,
        failureCategory: String?,
        at now: Date,
        in database: Database
    ) throws {
        let previous = try String.fetchOne(
            database,
            sql: "SELECT latestEventID FROM skillExecutionState WHERE proposalID = ?",
            arguments: [proposalID.uuidString])
        let eventID = try appendSkillEvent(
            proposalID: proposalID,
            previousEventID: previous,
            kind: kind,
            attempt: attempt,
            failureCategory: failureCategory,
            at: now,
            in: database)
        try database.execute(
            sql: """
                UPDATE skillExecutionState
                SET state = ?, attempt = ?, latestEventID = ?, updatedAt = ?
                WHERE proposalID = ?
                """,
            arguments: [state, attempt, eventID, now, proposalID.uuidString])
    }
}

public struct SkillExecutionHistoryEntry: Equatable, Sendable {
    public let kind: String
    public let attempt: Int
    public let failureCategory: FailureCategory?
    public let occurredAt: Date
}
