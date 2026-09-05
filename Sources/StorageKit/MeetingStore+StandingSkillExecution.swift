import Foundation
import GRDB
import PortavozCore

public enum StandingSkillExecutionRefusal: Equatable, Sendable {
    case invalidClaim
    case unknownRule
    case staleRule
    case ruleDisabled
    case allSkillsPaused
    case skillDisabled
    case eventDismissed
    case eventAlreadyOwned
    case ruleBusy
    case dailyBudgetReached
    case retryLimitReached
    case illegalTransition
}

public enum StandingSkillExecutionAdmission: Equatable, Sendable {
    case admitted(SkillExecutionRecord)
    case duplicate(SkillExecutionRecord)
    case refused(StandingSkillExecutionRefusal)
}

public enum StandingSkillExecutionMutation: Equatable, Sendable {
    case settled(SkillExecutionRecord)
    case alreadySettled(SkillExecutionRecord)
    case refused(StandingSkillExecutionRefusal)
}

public struct PendingStandingSkillExecution: Equatable, Sendable {
    public let record: SkillExecutionRecord
    public let ruleID: StandingSkillRuleID
    public let action: StandingSkillRuleAction
    public let occurrence: StandingSkillOccurrence
    public let authorizedAt: Date

    public init(
        record: SkillExecutionRecord,
        ruleID: StandingSkillRuleID,
        action: StandingSkillRuleAction,
        occurrence: StandingSkillOccurrence,
        authorizedAt: Date
    ) {
        self.record = record
        self.ruleID = ruleID
        self.action = action
        self.occurrence = occurrence
        self.authorizedAt = authorizedAt
    }
}

extension MeetingStore {
    /// Atomically consumes standing authority and a daily-budget slot. Every
    /// mutable gate is read again inside this transaction; a stale Settings
    /// snapshot or event observer is never execution authority.
    public func claimStandingSkillExecution(
        _ claim: StandingSkillExecutionClaim
    ) async throws -> StandingSkillExecutionAdmission {
        guard claim.isValid,
              Self.isValidSkillOfferKey(claim.oneShotOfferKey)
        else { return .refused(.invalidClaim) }

        return try await database.write { database in
            try Self.claimStandingSkillExecution(claim, in: database)
        }
    }

    /// Confirmed and failed local work is safe to regenerate after relaunch.
    /// Executing rows remain visible but are never implicitly repeated.
    public func pendingStandingSkillExecutions(
        limit: Int = StandingSkillExecutionPolicy.maximumPendingExecutionCount
    ) async throws -> [PendingStandingSkillExecution] {
        guard (1...StandingSkillExecutionPolicy.maximumPendingExecutionCount)
            .contains(limit)
        else { return [] }
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT execution.proposalID, execution.skillID,
                           execution.skillVersion, execution.idempotencyKey,
                           execution.state, execution.failureCategory,
                           execution.attempt, execution.updatedAt,
                           authority.ruleID, authority.action,
                           authority.occurrenceFingerprint,
                           authority.eventStartAt, authority.authorizedAt,
                           subject.calendarEventID
                    FROM standingSkillExecutionAuthority AS authority
                    JOIN skillExecutionState AS execution
                      ON execution.proposalID = authority.proposalID
                    JOIN skillExecutionSubject AS subject
                      ON subject.proposalID = execution.proposalID
                    WHERE execution.state IN (
                        'confirmed', 'failed', 'executing'
                    )
                    ORDER BY authority.authorizedAt ASC,
                             execution.proposalID ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.pendingStandingSkillExecution(from:))
        }
    }

    /// Commits the contentful local artifact and its begin/succeed receipt in
    /// one transaction. A crash can therefore leave either retryable work or
    /// a complete draft, never an ambiguous half-published effect.
    public func completeStandingSkillExecution(
        proposalID: UUID,
        artifact: StandingSkillArtifact,
        at timestamp: Date
    ) async throws -> StandingSkillExecutionMutation {
        guard artifact.isValid,
              artifact.createdAt == timestamp,
              timestamp.timeIntervalSinceReferenceDate.isFinite
        else { return .refused(.illegalTransition) }
        return try await database.write { database in
            try Self.completeStandingSkillExecution(
                proposalID: proposalID,
                artifact: artifact,
                at: timestamp,
                in: database)
        }
    }

    /// Records a preparation failure without exposing an `executing` window.
    /// Failed work is retryable only up to the standing-rule attempt ceiling.
    public func failStandingSkillExecution(
        proposalID: UUID,
        category: FailureCategory,
        at timestamp: Date
    ) async throws -> StandingSkillExecutionMutation {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            return .refused(.illegalTransition)
        }
        return try await database.write { database in
            guard try Self.hasStandingAuthority(
                proposalID,
                action: .preparePreMeetingBrief,
                in: database),
                  let existing = try Self.skillExecution(
                    proposalID,
                    in: database)
            else { return .refused(.illegalTransition) }
            guard existing.state == .confirmed || existing.state == .failed
            else { return .alreadySettled(existing) }
            guard let attempt = Self.nextStandingAutomaticAttempt(
                for: existing)
            else { return .refused(.retryLimitReached) }
            try Self.advanceSkillExecution(
                SkillExecutionTransition(
                    proposalID: proposalID,
                    transition: .begin,
                    attempt: attempt,
                    occurredAt: timestamp),
                in: database)
            try Self.advanceSkillExecution(
                SkillExecutionTransition(
                    proposalID: proposalID,
                    transition: .failed(category),
                    attempt: attempt,
                    occurredAt: timestamp),
                in: database)
            guard let settled = try Self.skillExecution(
                proposalID,
                in: database)
            else {
                throw StorageError.invalidStandingSkillExecution(
                    "failed owner disappeared")
            }
            return .settled(settled)
        }
    }

    public func standingSkillArtifact(
        proposalID: UUID
    ) async throws -> StandingSkillArtifact? {
        try await database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT kind, formatVersion, payload, sha256, createdAt
                    FROM standingSkillArtifact
                    WHERE proposalID = ?
                    """,
                arguments: [proposalID.uuidString])
            else { return nil }
            return try Self.standingSkillArtifact(from: row)
        }
    }
}

private enum StandingSkillRuleAdmission {
    case admitted(StandingSkillRule)
    case refused(StandingSkillExecutionRefusal)
}

private extension MeetingStore {
    static func completeStandingSkillExecution(
        proposalID: UUID,
        artifact: StandingSkillArtifact,
        at timestamp: Date,
        in database: Database
    ) throws -> StandingSkillExecutionMutation {
        guard try hasStandingAuthority(
            proposalID,
            action: .preparePreMeetingBrief,
            in: database),
              let existing = try skillExecution(proposalID, in: database)
        else { return .refused(.illegalTransition) }
        if existing.state == .succeeded {
            return .alreadySettled(existing)
        }
        guard existing.state == .confirmed || existing.state == .failed
        else { return .refused(.illegalTransition) }
        if let refusal = try standingCompletionRefusal(
            proposalID: proposalID,
            execution: existing,
            in: database
        ) {
            return .refused(refusal)
        }
        guard let attempt = nextStandingAutomaticAttempt(for: existing)
        else { return .refused(.retryLimitReached) }
        return try publishStandingArtifact(
            proposalID: proposalID,
            artifact: artifact,
            attempt: attempt,
            at: timestamp,
            in: database)
    }

    static func publishStandingArtifact(
        proposalID: UUID,
        artifact: StandingSkillArtifact,
        attempt: Int,
        at timestamp: Date,
        in database: Database
    ) throws -> StandingSkillExecutionMutation {
        try advanceSkillExecution(
            SkillExecutionTransition(
                proposalID: proposalID,
                transition: .begin,
                attempt: attempt,
                occurredAt: timestamp),
            in: database)
        try database.execute(
            sql: """
                INSERT INTO standingSkillArtifact (
                    proposalID, kind, formatVersion, payload,
                    sha256, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                proposalID.uuidString,
                artifact.kind.rawValue,
                artifact.formatVersion,
                artifact.payload,
                artifact.sha256,
                artifact.createdAt
            ])
        try advanceSkillExecution(
            SkillExecutionTransition(
                proposalID: proposalID,
                transition: .succeeded,
                attempt: attempt,
                occurredAt: timestamp),
            in: database)
        guard let settled = try skillExecution(proposalID, in: database)
        else {
            throw StorageError.invalidStandingSkillExecution(
                "completed owner disappeared")
        }
        return .settled(settled)
    }

    static func claimStandingSkillExecution(
        _ claim: StandingSkillExecutionClaim,
        in database: Database
    ) throws -> StandingSkillExecutionAdmission {
        let rule: StandingSkillRule
        switch try standingRuleAdmission(for: claim, in: database) {
        case .refused(let refusal):
            return .refused(refusal)
        case .admitted(let admittedRule):
            rule = admittedRule
        }
        if let duplicate = try standingExecutionRecord(
            action: claim.action,
            occurrenceFingerprint: claim.occurrence.fingerprint,
            in: database
        ) {
            return .duplicate(duplicate)
        }
        if let refusal = try standingOccurrenceRefusal(
            for: claim,
            in: database)
            ?? standingCapacityRefusal(
                for: claim,
                rule: rule,
                in: database) {
            return .refused(refusal)
        }
        return try insertStandingExecution(claim, in: database)
    }

    static func standingRuleAdmission(
        for claim: StandingSkillExecutionClaim,
        in database: Database
    ) throws -> StandingSkillRuleAdmission {
        guard let ruleRow = try Row.fetchOne(
            database,
            sql: """
                SELECT id, skillID, skillVersion, trigger,
                       subjectPredicate, action,
                       maximumDailyExecutions, isEnabled,
                       createdAt, updatedAt
                FROM standingSkillRule
                WHERE id = ?
                """,
            arguments: [claim.ruleID.rawValue.uuidString])
        else { return .refused(.unknownRule) }
        let rule = try standingSkillRule(from: ruleRow)
        guard rule.skillID == claim.skillID,
              rule.skillVersion == claim.skillVersion,
              rule.trigger == claim.trigger,
              rule.subjectPredicate == claim.subjectPredicate,
              rule.action == claim.action
        else { return .refused(.staleRule) }
        guard rule.isEnabled else { return .refused(.ruleDisabled) }
        guard let isPaused = try Bool.fetchOne(
            database,
            sql: "SELECT isPaused FROM skillControl WHERE id = 1")
        else {
            throw StorageError.invalidPersistedValue(
                table: "skillControl",
                column: "id",
                value: "missing singleton")
        }
        guard !isPaused else { return .refused(.allSkillsPaused) }
        let isDisabled = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM skillDisablement WHERE skillID = ?
                )
                """,
            arguments: [claim.skillID]) ?? false
        return isDisabled ? .refused(.skillDisabled) : .admitted(rule)
    }

    static func standingOccurrenceRefusal(
        for claim: StandingSkillExecutionClaim,
        in database: Database
    ) throws -> StandingSkillExecutionRefusal? {
        let dismissed = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM skillOfferDismissal WHERE offerKey = ?
                )
                """,
            arguments: [claim.oneShotOfferKey]) ?? false
        if dismissed { return .eventDismissed }
        let exactEventHasOwner = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM skillExecutionState AS execution
                    JOIN skillExecutionSubject AS subject
                      ON subject.proposalID = execution.proposalID
                    WHERE execution.skillID = ?
                      AND subject.subjectKind = 'calendar-event'
                      AND subject.calendarEventID = ?
                )
                """,
            arguments: [claim.skillID, claim.occurrence.eventID]) ?? false
        return exactEventHasOwner ? .eventAlreadyOwned : nil
    }

    static func standingCapacityRefusal(
        for claim: StandingSkillExecutionClaim,
        rule: StandingSkillRule,
        in database: Database
    ) throws -> StandingSkillExecutionRefusal? {
        let isBusy = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM standingSkillExecutionAuthority AS authority
                    JOIN skillExecutionState AS execution
                      ON execution.proposalID = authority.proposalID
                    WHERE authority.ruleID = ?
                      AND execution.state IN ('confirmed', 'executing')
                )
                """,
            arguments: [claim.ruleID.rawValue.uuidString]) ?? false
        if isBusy { return .ruleBusy }
        let dailyCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM standingSkillExecutionAuthority
                WHERE ruleID = ?
                  AND authorizedAt >= ?
                  AND authorizedAt < ?
                """,
            arguments: [
                claim.ruleID.rawValue.uuidString,
                claim.dailyWindow.startInclusive,
                claim.dailyWindow.endExclusive
            ]) ?? 0
        if dailyCount >= rule.maximumDailyExecutions {
            return .dailyBudgetReached
        }
        guard try skillExecution(claim.proposalID, in: database) == nil,
              try !isStandingIdempotencyKeyClaimed(
                claim.idempotencyKey,
                in: database)
        else { return .invalidClaim }
        return nil
    }

    static func insertStandingExecution(
        _ claim: StandingSkillExecutionClaim,
        in database: Database
    ) throws -> StandingSkillExecutionAdmission {
        let confirmation = SkillExecutionConfirmation(
            proposalID: claim.proposalID,
            skillID: claim.skillID,
            skillVersion: claim.skillVersion,
            subject: .calendarEvent(claim.occurrence.eventID),
            offerKey: claim.idempotencyKey,
            idempotencyKey: claim.idempotencyKey,
            occurredAt: claim.occurredAt)
        guard case .admitted(let record) = try insertSkillExecution(
            confirmation,
            in: database)
        else {
            throw StorageError.invalidStandingSkillExecution(
                "claim did not create one execution owner")
        }
        try database.execute(
            sql: """
                INSERT INTO standingSkillExecutionAuthority (
                    proposalID, ruleID, action, occurrenceFingerprint,
                    eventStartAt, budgetWindowStart, budgetWindowEnd,
                    authorizedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                claim.proposalID.uuidString,
                claim.ruleID.rawValue.uuidString,
                claim.action.rawValue,
                claim.occurrence.fingerprint,
                claim.occurrence.eventStartAt,
                claim.dailyWindow.startInclusive,
                claim.dailyWindow.endExclusive,
                claim.occurredAt
            ])
        return .admitted(record)
    }

    static func nextStandingAutomaticAttempt(
        for execution: SkillExecutionRecord
    ) -> Int? {
        switch execution.state {
        case .confirmed:
            return execution.attempt == 1 ? 1 : nil
        case .failed:
            guard execution.attempt >= 1,
                  execution.attempt
                    < StandingSkillExecutionPolicy.maximumAutomaticAttempts
            else { return nil }
            return execution.attempt + 1
        case .proposed, .previewed, .executing, .succeeded, .dismissed:
            return nil
        }
    }

    static func standingExecutionRecord(
        action: StandingSkillRuleAction,
        occurrenceFingerprint: String,
        in database: Database
    ) throws -> SkillExecutionRecord? {
        guard let rawID = try String.fetchOne(
            database,
            sql: """
                SELECT proposalID
                FROM standingSkillExecutionAuthority
                WHERE action = ? AND occurrenceFingerprint = ?
                """,
            arguments: [action.rawValue, occurrenceFingerprint])
        else { return nil }
        guard let proposalID = UUID(uuidString: rawID),
              let record = try skillExecution(proposalID, in: database)
        else {
            throw StorageError.invalidStandingSkillExecution(
                "duplicate authority has no valid execution owner")
        }
        return record
    }

    static func isStandingIdempotencyKeyClaimed(
        _ key: String,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM skillExecutionState WHERE idempotencyKey = ?
                )
                """,
            arguments: [key]) ?? false
    }

    static func hasStandingAuthority(
        _ proposalID: UUID,
        action: StandingSkillRuleAction,
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM standingSkillExecutionAuthority
                    WHERE proposalID = ? AND action = ?
                )
                """,
            arguments: [proposalID.uuidString, action.rawValue]) ?? false
    }

    static func standingCompletionRefusal(
        proposalID: UUID,
        execution: SkillExecutionRecord,
        in database: Database
    ) throws -> StandingSkillExecutionRefusal? {
        guard let authority = try Row.fetchOne(
            database,
            sql: """
                SELECT ruleID, action
                FROM standingSkillExecutionAuthority
                WHERE proposalID = ?
                """,
            arguments: [proposalID.uuidString])
        else { return .illegalTransition }
        let rawRuleID: String = authority["ruleID"]
        guard let ruleRow = try Row.fetchOne(
            database,
            sql: """
                SELECT id, skillID, skillVersion, trigger,
                       subjectPredicate, action,
                       maximumDailyExecutions, isEnabled,
                       createdAt, updatedAt
                FROM standingSkillRule
                WHERE id = ?
                """,
            arguments: [rawRuleID])
        else { return .unknownRule }
        let rule = try standingSkillRule(from: ruleRow)
        let rawAction: String = authority["action"]
        guard rule.skillID == execution.skillID,
              rule.skillVersion == execution.skillVersion,
              rule.action.rawValue == rawAction
        else { return .staleRule }
        guard rule.isEnabled else { return .ruleDisabled }
        guard let isPaused = try Bool.fetchOne(
            database,
            sql: "SELECT isPaused FROM skillControl WHERE id = 1")
        else {
            throw StorageError.invalidPersistedValue(
                table: "skillControl",
                column: "id",
                value: "missing singleton")
        }
        guard !isPaused else { return .allSkillsPaused }
        let isDisabled = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM skillDisablement WHERE skillID = ?
                )
                """,
            arguments: [execution.skillID]) ?? false
        return isDisabled ? .skillDisabled : nil
    }

    static func pendingStandingSkillExecution(
        from row: Row
    ) throws -> PendingStandingSkillExecution {
        let rawRuleID: String = row["ruleID"]
        let rawEventID: String? = row["calendarEventID"]
        let rawAction: String = row["action"]
        guard let ruleUUID = UUID(uuidString: rawRuleID) else {
            throw StorageError.invalidPersistedUUID(
                table: "standingSkillExecutionAuthority",
                column: "ruleID",
                value: rawRuleID)
        }
        guard let eventID = rawEventID,
              let action = StandingSkillRuleAction(rawValue: rawAction)
        else {
            throw StorageError.invalidStandingSkillExecution(
                "pending owner has no valid event or action")
        }
        let eventStartAt: Date = row["eventStartAt"]
        let occurrence = StandingSkillOccurrence(
            eventID: eventID,
            eventStartAt: eventStartAt)
        let persistedFingerprint: String = row["occurrenceFingerprint"]
        guard occurrence.isValid,
              occurrence.fingerprint == persistedFingerprint
        else {
            throw StorageError.invalidStandingSkillExecution(
                "pending occurrence fingerprint mismatch")
        }
        let authorizedAt: Date = row["authorizedAt"]
        guard authorizedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidStandingSkillExecution(
                "pending authority has invalid timestamp")
        }
        let record = try skillExecutionRecord(from: row)
        guard isValidPendingStandingExecution(record) else {
            throw StorageError.invalidStandingSkillExecution(
                "pending owner has invalid state or attempt")
        }
        return PendingStandingSkillExecution(
            record: record,
            ruleID: StandingSkillRuleID(rawValue: ruleUUID),
            action: action,
            occurrence: occurrence,
            authorizedAt: authorizedAt)
    }

    static func isValidPendingStandingExecution(
        _ record: SkillExecutionRecord
    ) -> Bool {
        switch record.state {
        case .confirmed:
            record.attempt == 1
        case .failed, .executing:
            (1...StandingSkillExecutionPolicy.maximumAutomaticAttempts)
                .contains(record.attempt)
        case .proposed, .previewed, .succeeded, .dismissed:
            false
        }
    }

    static func standingSkillArtifact(
        from row: Row
    ) throws -> StandingSkillArtifact {
        let rawKind: String = row["kind"]
        guard let kind = StandingSkillArtifact.Kind(rawValue: rawKind) else {
            throw StorageError.invalidStandingSkillExecution(
                "unknown artifact kind")
        }
        let payload: Data = row["payload"]
        let artifact = StandingSkillArtifact(
            kind: kind,
            formatVersion: row["formatVersion"],
            payload: payload,
            createdAt: row["createdAt"])
        let persistedDigest: String = row["sha256"]
        guard artifact.isValid, artifact.sha256 == persistedDigest else {
            throw StorageError.invalidStandingSkillExecution(
                "artifact digest or bounds mismatch")
        }
        return artifact
    }
}
