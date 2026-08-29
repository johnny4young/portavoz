import Foundation
import GRDB
import PortavozCore

/// One bounded, content-free row for the standing-action control surface.
/// The opaque calendar identity is retained only so ApplicationKit can bind a
/// prepared artifact to the exact occurrence that authorized it.
public struct StandingSkillExecutionReceipt: Equatable, Sendable, Identifiable {
    public let record: SkillExecutionRecord
    public let ruleID: StandingSkillRuleID
    public let action: StandingSkillRuleAction
    public let occurrence: StandingSkillOccurrence
    public let authorizedAt: Date
    public let hasArtifact: Bool

    public var id: UUID { record.proposalID }

    public init(
        record: SkillExecutionRecord,
        ruleID: StandingSkillRuleID,
        action: StandingSkillRuleAction,
        occurrence: StandingSkillOccurrence,
        authorizedAt: Date,
        hasArtifact: Bool
    ) {
        self.record = record
        self.ruleID = ruleID
        self.action = action
        self.occurrence = occurrence
        self.authorizedAt = authorizedAt
        self.hasArtifact = hasArtifact
    }
}

extension MeetingStore {
    /// Reads only executions created from standing authority. One successor
    /// row may be requested by ApplicationKit to prove bounded continuation.
    public func standingSkillExecutionReceipts(
        limit: Int
    ) async throws -> [StandingSkillExecutionReceipt] {
        guard (1...51).contains(limit) else { return [] }
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
                           subject.calendarEventID,
                           artifact.proposalID AS artifactProposalID
                    FROM standingSkillExecutionAuthority AS authority
                    JOIN skillExecutionState AS execution
                      ON execution.proposalID = authority.proposalID
                    JOIN skillExecutionSubject AS subject
                      ON subject.proposalID = execution.proposalID
                    LEFT JOIN standingSkillArtifact AS artifact
                      ON artifact.proposalID = execution.proposalID
                    ORDER BY execution.updatedAt DESC,
                             execution.proposalID ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.standingSkillExecutionReceipt(from:))
        }
    }
}

private extension MeetingStore {
    static func standingSkillExecutionReceipt(
        from row: Row
    ) throws -> StandingSkillExecutionReceipt {
        let record = try skillExecutionRecord(from: row)
        let rawRuleID: String = row["ruleID"]
        let rawAction: String = row["action"]
        let rawEventID: String? = row["calendarEventID"]
        guard let ruleUUID = UUID(uuidString: rawRuleID) else {
            throw StorageError.invalidPersistedUUID(
                table: "standingSkillExecutionAuthority",
                column: "ruleID",
                value: rawRuleID)
        }
        guard let action = StandingSkillRuleAction(rawValue: rawAction),
              let eventID = rawEventID
        else {
            throw StorageError.invalidStandingSkillExecution(
                "history row has no valid event or action")
        }
        let occurrence = StandingSkillOccurrence(
            eventID: eventID,
            eventStartAt: row["eventStartAt"])
        let persistedFingerprint: String = row["occurrenceFingerprint"]
        let authorizedAt: Date = row["authorizedAt"]
        let artifactID: String? = row["artifactProposalID"]
        let hasArtifact = artifactID != nil
        guard occurrence.isValid else {
            throw StorageError.invalidStandingSkillExecution(
                "history occurrence is invalid")
        }
        guard occurrence.fingerprint == persistedFingerprint else {
            throw StorageError.invalidStandingSkillExecution(
                "history occurrence fingerprint mismatch")
        }
        guard authorizedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidStandingSkillExecution(
                "history authorization timestamp is invalid")
        }
        guard isValidStandingHistoryRecord(record) else {
            throw StorageError.invalidStandingSkillExecution(
                "history execution state or attempt is invalid")
        }
        guard (record.state == .succeeded) == hasArtifact else {
            throw StorageError.invalidStandingSkillExecution(
                "history artifact does not match succeeded state")
        }
        guard artifactID == nil
                || artifactID == record.proposalID.uuidString
        else {
            throw StorageError.invalidStandingSkillExecution(
                "history artifact owner mismatch")
        }
        return StandingSkillExecutionReceipt(
            record: record,
            ruleID: StandingSkillRuleID(rawValue: ruleUUID),
            action: action,
            occurrence: occurrence,
            authorizedAt: authorizedAt,
            hasArtifact: hasArtifact)
    }

    static func isValidStandingHistoryRecord(
        _ record: SkillExecutionRecord
    ) -> Bool {
        switch record.state {
        case .confirmed, .dismissed:
            record.attempt == 1
        case .failed, .executing, .succeeded:
            (1...StandingSkillExecutionPolicy.maximumAutomaticAttempts)
                .contains(record.attempt)
        case .proposed, .previewed:
            false
        }
    }
}
