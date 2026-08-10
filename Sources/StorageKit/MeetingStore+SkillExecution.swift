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
                SkillExecutionEventWrite(
                    proposalID: proposalID,
                    previousEventID: nil,
                    kind: .confirm,
                    attempt: 1,
                    failureCategory: nil,
                    occurredAt: now),
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
                SkillExecutionTransition(
                    proposalID: proposalID,
                    transition: .begin,
                    attempt: attempt,
                    occurredAt: now),
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
            let transition: PersistedSkillExecutionTransition
            switch (succeeded, failureCategory) {
            case (true, nil):
                transition = .succeeded
            case (false, .some(let category)):
                transition = .failed(category)
            default:
                return .rejected(.illegalTransition)
            }
            try Self.advanceSkillExecution(
                SkillExecutionTransition(
                    proposalID: proposalID,
                    transition: transition,
                    attempt: existing.attempt,
                    occurredAt: now),
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
                SkillExecutionTransition(
                    proposalID: proposalID,
                    transition: .cancelled,
                    attempt: existing.attempt,
                    occurredAt: now),
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

    /// Resolves the one durable owner of an intended effect. Presentation may
    /// reconstruct a confirmation sheet after a failed attempt, but the unique
    /// idempotency key still belongs to the original proposal UUID; retry must
    /// resume that owner rather than manufacture a competing claim.
    public func skillExecution(
        idempotencyKey: String
    ) async throws -> SkillExecutionRecord? {
        let trimmed = idempotencyKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == idempotencyKey else { return nil }
        return try await database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, attempt, updatedAt
                    FROM skillExecutionState
                    WHERE idempotencyKey = ?
                    """,
                arguments: [idempotencyKey])
            else { return nil }
            return try Self.skillExecutionRecord(from: row)
        }
    }

    /// Bounded batch lookup for subject surfaces. One Radar render must not
    /// become one SQLite query per commitment as the page grows.
    public func skillExecutions(
        idempotencyKeys: [String]
    ) async throws -> [SkillExecutionRecord] {
        guard !idempotencyKeys.isEmpty,
              idempotencyKeys.count <= 200,
              Set(idempotencyKeys).count == idempotencyKeys.count,
              idempotencyKeys.allSatisfy({ key in
                  let trimmed = key.trimmingCharacters(
                      in: .whitespacesAndNewlines)
                  return !trimmed.isEmpty && trimmed == key
              })
        else { return [] }
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, attempt, updatedAt
                    FROM skillExecutionState
                    WHERE idempotencyKey IN (
                        \(databaseQuestionMarks(count: idempotencyKeys.count))
                    )
                    """,
                arguments: StatementArguments(idempotencyKeys)
            ).map(Self.skillExecutionRecord(from:))
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
        //
        // An unrecognised state must read as "this may already have acted",
        // never as `.failed`: `.failed` is the one state `beginSkillExecution`
        // treats as retryable, so defaulting there would let a row written by a
        // newer build be re-run. `.executing` is the fail-closed reading — the
        // caller reconciles instead of repeating.
        let state = skillExecutionState(from: raw)
        return SkillExecutionRecord(
            proposalID: proposalID,
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            idempotencyKey: row["idempotencyKey"],
            state: state,
            attempt: row["attempt"],
            updatedAt: row["updatedAt"])
    }

    /// One strict decoder for list projections. Receipt history is audit
    /// evidence: a malformed durable identity must fail the read rather than
    /// silently disappearing from the UI.
    static func skillExecutionRecord(
        from row: Row
    ) throws -> SkillExecutionRecord {
        let rawProposalID: String = row["proposalID"]
        guard let proposalID = UUID(uuidString: rawProposalID) else {
            throw StorageError.invalidPersistedUUID(
                table: "skillExecutionState",
                column: "proposalID",
                value: rawProposalID)
        }
        let rawState: String = row["state"]
        return SkillExecutionRecord(
            proposalID: proposalID,
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            idempotencyKey: row["idempotencyKey"],
            state: skillExecutionState(from: rawState),
            attempt: row["attempt"],
            updatedAt: row["updatedAt"])
    }

    /// One fail-closed decoder for every projection of durable skill state.
    ///
    /// Storage spells a pre-handoff cancellation `cancelled`, while the
    /// domain calls that terminal no-effect state `dismissed`. Keeping this
    /// translation here also means a state written by a newer build can never
    /// disappear from receipts or accidentally become retryable.
    static func skillExecutionState(from raw: String) -> SkillExecutionState {
        switch raw {
        case "cancelled": .dismissed
        default: SkillExecutionState(rawValue: raw) ?? .executing
        }
    }

    private static func appendSkillEvent(
        _ event: SkillExecutionEventWrite,
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
                eventID, event.proposalID.uuidString, event.previousEventID,
                event.kind.rawValue, event.attempt,
                event.failureCategory?.rawValue, event.occurredAt
            ])
        return eventID
    }

    private static func advanceSkillExecution(
        _ transition: SkillExecutionTransition,
        in database: Database
    ) throws {
        let previous = try String.fetchOne(
            database,
            sql: "SELECT latestEventID FROM skillExecutionState WHERE proposalID = ?",
            arguments: [transition.proposalID.uuidString])
        let eventID = try appendSkillEvent(
            transition.event(previousEventID: previous),
            in: database)
        // The projection's updatedAt is monotonic, clamped in SQL rather than
        // trusted from the wall clock. A backward clock step between confirm
        // and settle would otherwise fail the `updatedAt >= createdAt` CHECK
        // and leave the row stuck in `executing` — the one state that means
        // "the effect may already have happened", so the proposal could never
        // be settled or retried. The event log keeps the unclamped truth: its
        // occurredAt is whatever the clock said.
        try database.execute(
            sql: """
                UPDATE skillExecutionState
                SET state = ?, attempt = ?, latestEventID = ?,
                    updatedAt = MAX(?, updatedAt)
                WHERE proposalID = ?
                """,
            arguments: [
                transition.transition.state,
                transition.attempt,
                eventID,
                transition.occurredAt,
                transition.proposalID.uuidString
            ])
    }
}

private struct SkillExecutionEventWrite {
    let proposalID: UUID
    let previousEventID: String?
    let kind: PersistedSkillExecutionEventKind
    let attempt: Int
    let failureCategory: FailureCategory?
    let occurredAt: Date
}

private struct SkillExecutionTransition {
    let proposalID: UUID
    let transition: PersistedSkillExecutionTransition
    let attempt: Int
    let occurredAt: Date

    func event(previousEventID: String?) -> SkillExecutionEventWrite {
        SkillExecutionEventWrite(
            proposalID: proposalID,
            previousEventID: previousEventID,
            kind: transition.eventKind,
            attempt: attempt,
            failureCategory: transition.failureCategory,
            occurredAt: occurredAt)
    }
}

private enum PersistedSkillExecutionEventKind: String {
    case confirm
    case begin
    case succeed
    case fail
    case cancel
}

private enum PersistedSkillExecutionTransition {
    case begin
    case succeeded
    case failed(FailureCategory)
    case cancelled

    var eventKind: PersistedSkillExecutionEventKind {
        switch self {
        case .begin: .begin
        case .succeeded: .succeed
        case .failed: .fail
        case .cancelled: .cancel
        }
    }

    var state: String {
        switch self {
        case .begin: "executing"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    var failureCategory: FailureCategory? {
        switch self {
        case .failed(let category): category
        case .begin, .succeeded, .cancelled: nil
        }
    }
}

public struct SkillExecutionHistoryEntry: Equatable, Sendable {
    public let kind: String
    public let attempt: Int
    public let failureCategory: FailureCategory?
    public let occurredAt: Date
}
