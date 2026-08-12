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
    /// A durable offer-level dismissal won the race before this claim. An
    /// already-open confirmation surface is not authority to continue.
    case offerDismissed = "offer-dismissed"
    case unknownExecution = "unknown-execution"
    case illegalTransition = "illegal-transition"
}

public struct SkillExecutionRecord: Equatable, Sendable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let idempotencyKey: String
    public let state: SkillExecutionState
    public let failureCategory: FailureCategory?
    public let attempt: Int
    public let updatedAt: Date

    public init(
        proposalID: UUID,
        skillID: String,
        skillVersion: Int,
        idempotencyKey: String,
        state: SkillExecutionState,
        failureCategory: FailureCategory?,
        attempt: Int,
        updatedAt: Date
    ) {
        self.proposalID = proposalID
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.failureCategory = failureCategory
        self.attempt = attempt
        self.updatedAt = updatedAt
    }
}

extension MeetingStore {
    public static let maximumSkillExecutionAuditEventCount = 256

    /// Records the user's confirmation durably before anything runs.
    ///
    /// This is the idempotency boundary: the effect belongs to one
    /// `idempotencyKey`, and a second confirmation of the same proposal returns
    /// the existing record rather than creating a second claim on it.
    public func confirmSkillExecution(
        _ confirmation: SkillExecutionConfirmation
    ) async throws -> SkillExecutionAdmission {
        let trimmedSkill = confirmation.skillID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let trimmedKey = confirmation.idempotencyKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedSkill.isEmpty,
              trimmedSkill == confirmation.skillID,
              !trimmedKey.isEmpty,
              Self.isValidSkillOfferKey(confirmation.offerKey),
              confirmation.idempotencyKey == confirmation.offerKey
                || confirmation.idempotencyKey.hasPrefix(
                    confirmation.offerKey + ":"),
              confirmation.skillVersion >= 1,
              confirmation.subject.isValid
        else { return .rejected(.invalidProposal) }

        return try await database.write { database in
            try Self.confirmSkillExecution(
                confirmation,
                in: database)
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
            try Self.skillExecutionHistory(proposalID, in: database).entries
        }
    }

    /// One read-consistent, content-free receipt inspection snapshot.
    ///
    /// State and append-only events must come from the same SQLite snapshot;
    /// reading them separately could render a terminal state beside a timeline
    /// that still ends at `begin` while another process settles the attempt.
    public func skillExecutionAudit(
        proposalID: UUID
    ) async throws -> SkillExecutionAudit? {
        try await database.read { database in
            guard let record = try Self.skillExecution(proposalID, in: database)
            else { return nil }
            let history = try Self.skillExecutionHistory(
                proposalID,
                in: database,
                limit: Self.maximumSkillExecutionAuditEventCount + 1)
            guard history.entries.count <= Self.maximumSkillExecutionAuditEventCount else {
                throw StorageError.invalidPersistedValue(
                    table: "skillExecutionEvent",
                    column: "proposalID",
                    value: "history exceeds inspection limit")
            }
            let projectedLatestEventID = try String.fetchOne(
                database,
                sql: "SELECT latestEventID FROM skillExecutionState WHERE proposalID = ?",
                arguments: [proposalID.uuidString])
            guard history.latestEventID == projectedLatestEventID else {
                throw StorageError.invalidPersistedValue(
                    table: "skillExecutionState",
                    column: "latestEventID",
                    value: projectedLatestEventID ?? "missing")
            }
            return SkillExecutionAudit(
                record: record,
                history: history.entries,
                subject: try Self.skillExecutionSubject(
                    proposalID,
                    in: database))
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
        guard !trimmed.isEmpty else { return nil }
        return try await database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, failureCategory, attempt, updatedAt
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
                           state, failureCategory, attempt, updatedAt
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

    private static func confirmSkillExecution(
        _ confirmation: SkillExecutionConfirmation,
        in database: Database
    ) throws -> SkillExecutionAdmission {
        // A claim that committed before a later offer dismissal already owns
        // this exact effect. The tombstone fences only claims not yet created.
        if let existing = try skillExecution(confirmation.proposalID, in: database) {
            return try resolveExistingSkillExecution(
                existing,
                confirmation: confirmation,
                in: database)
        }

        let dismissed = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM skillOfferDismissal WHERE offerKey = ?
                )
                """,
            arguments: [confirmation.offerKey]) ?? false
        guard !dismissed else { return .rejected(.offerDismissed) }

        guard try !isSkillExecutionClaimed(
            confirmation.idempotencyKey,
            in: database
        ) else { return .rejected(.idempotencyKeyClaimed) }

        return try insertSkillExecution(confirmation, in: database)
    }

    private static func resolveExistingSkillExecution(
        _ existing: SkillExecutionRecord,
        confirmation: SkillExecutionConfirmation,
        in database: Database
    ) throws -> SkillExecutionAdmission {
        guard existing.idempotencyKey == confirmation.idempotencyKey else {
            return .rejected(.idempotencyKeyClaimed)
        }
        guard try recordSkillExecutionSubject(
            proposalID: confirmation.proposalID,
            subject: confirmation.subject,
            in: database)
        else { return .rejected(.invalidProposal) }
        try retireOneShotOffer(
            offerKey: confirmation.offerKey,
            idempotencyKey: confirmation.idempotencyKey,
            in: database)
        return .alreadySettled(existing)
    }

    private static func insertSkillExecution(
        _ confirmation: SkillExecutionConfirmation,
        in database: Database
    ) throws -> SkillExecutionAdmission {
        let eventID = try appendSkillEvent(
            SkillExecutionEventWrite(
                proposalID: confirmation.proposalID,
                previousEventID: nil,
                kind: .confirm,
                attempt: 1,
                failureCategory: nil,
                occurredAt: confirmation.occurredAt),
            in: database)
        try database.execute(
            sql: """
                INSERT INTO skillExecutionState (
                    proposalID, skillID, skillVersion, idempotencyKey,
                    state, attempt, latestEventID, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, 'confirmed', 1, ?, ?, ?)
                """,
            arguments: [
                confirmation.proposalID.uuidString,
                confirmation.skillID,
                confirmation.skillVersion,
                confirmation.idempotencyKey,
                eventID,
                confirmation.occurredAt,
                confirmation.occurredAt
            ])
        guard let record = try skillExecution(confirmation.proposalID, in: database) else {
            return .rejected(.unknownExecution)
        }
        guard try recordSkillExecutionSubject(
            proposalID: confirmation.proposalID,
            subject: confirmation.subject,
            in: database)
        else { return .rejected(.invalidProposal) }
        try retireOneShotOffer(
            offerKey: confirmation.offerKey,
            idempotencyKey: confirmation.idempotencyKey,
            in: database)
        return .admitted(record)
    }

    private static func isSkillExecutionClaimed(
        _ idempotencyKey: String,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM skillExecutionState WHERE idempotencyKey = ?
                )
                """,
            arguments: [idempotencyKey]) ?? false
    }

    /// Exact one-shot offers own one effect slot. A package export is reusable
    /// and keeps its destination-free proposal while each destination claims a
    /// distinct idempotency key.
    private static func retireOneShotOffer(
        offerKey: String,
        idempotencyKey: String,
        in database: Database
    ) throws {
        guard offerKey == idempotencyKey else { return }
        try database.execute(
            sql: "DELETE FROM skillOfferProposal WHERE offerKey = ?",
            arguments: [offerKey])
    }

    private static func skillExecution(
        _ proposalID: UUID,
        in database: Database
    ) throws -> SkillExecutionRecord? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT proposalID, skillID, skillVersion, idempotencyKey,
                       state, failureCategory, attempt, updatedAt
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
        let failureCategory = try skillFailureCategory(
            from: row,
            state: state)
        return SkillExecutionRecord(
            proposalID: proposalID,
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            idempotencyKey: row["idempotencyKey"],
            state: state,
            failureCategory: failureCategory,
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
        let state = skillExecutionState(from: rawState)
        return SkillExecutionRecord(
            proposalID: proposalID,
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            idempotencyKey: row["idempotencyKey"],
            state: state,
            failureCategory: try skillFailureCategory(
                from: row,
                state: state),
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

    private static func skillFailureCategory(
        from row: Row,
        state: SkillExecutionState
    ) throws -> FailureCategory? {
        let rawCategory: String? = row["failureCategory"]
        let category: FailureCategory?
        if let rawCategory {
            guard let decoded = FailureCategory(rawValue: rawCategory) else {
                throw StorageError.invalidPersistedValue(
                    table: "skillExecutionState",
                    column: "failureCategory",
                    value: rawCategory)
            }
            category = decoded
        } else {
            category = nil
        }
        guard (state == .failed) == (category != nil) else {
            throw StorageError.invalidPersistedValue(
                table: "skillExecutionState",
                column: "failureCategory",
                value: rawCategory ?? "missing")
        }
        return category
    }

    private static func skillExecutionHistory(
        _ proposalID: UUID,
        in database: Database,
        limit: Int? = nil
    ) throws -> SkillExecutionHistoryRead {
        let limitClause = limit == nil ? "" : " LIMIT ?"
        let arguments: StatementArguments = if let limit {
            [proposalID.uuidString, limit]
        } else {
            [proposalID.uuidString]
        }
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, previousEventID, kind, attempt,
                       failureCategory, occurredAt
                FROM skillExecutionEvent
                WHERE proposalID = ?
                ORDER BY rowid ASC
                """ + limitClause,
            arguments: arguments
        )
        var latestEventID: String?
        let entries = try rows.map { row in
            let eventID: String = row["id"]
            let previousEventID: String? = row["previousEventID"]
            guard previousEventID == latestEventID else {
                throw StorageError.invalidPersistedValue(
                    table: "skillExecutionEvent",
                    column: "previousEventID",
                    value: previousEventID ?? "missing")
            }
            latestEventID = eventID
            let rawCategory: String? = row["failureCategory"]
            let category: FailureCategory?
            if let rawCategory {
                guard let decoded = FailureCategory(rawValue: rawCategory) else {
                    throw StorageError.invalidPersistedValue(
                        table: "skillExecutionEvent",
                        column: "failureCategory",
                        value: rawCategory)
                }
                category = decoded
            } else {
                category = nil
            }
            return SkillExecutionHistoryEntry(
                kind: row["kind"],
                attempt: row["attempt"],
                failureCategory: category,
                occurredAt: row["occurredAt"])
        }
        return SkillExecutionHistoryRead(
            entries: entries,
            latestEventID: latestEventID)
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
                    failureCategory = ?, updatedAt = MAX(?, updatedAt)
                WHERE proposalID = ?
                """,
            arguments: [
                transition.transition.state,
                transition.attempt,
                eventID,
                transition.transition.failureCategory?.rawValue,
                transition.occurredAt,
                transition.proposalID.uuidString
            ])
    }
}

private struct SkillExecutionHistoryRead {
    let entries: [SkillExecutionHistoryEntry]
    let latestEventID: String?
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

    public init(
        kind: String,
        attempt: Int,
        failureCategory: FailureCategory?,
        occurredAt: Date
    ) {
        self.kind = kind
        self.attempt = attempt
        self.failureCategory = failureCategory
        self.occurredAt = occurredAt
    }
}

public struct SkillExecutionAudit: Equatable, Sendable {
    public let record: SkillExecutionRecord
    public let history: [SkillExecutionHistoryEntry]
    public let subject: SkillSubject?

    public init(
        record: SkillExecutionRecord,
        history: [SkillExecutionHistoryEntry],
        subject: SkillSubject? = nil
    ) {
        self.record = record
        self.history = history
        self.subject = subject
    }
}
