import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    /// Reads one bounded complete control-plane projection. An invalid limit
    /// yields no authority rather than widening to an unbounded query.
    public func standingSkillRules(
        limit: Int = StandingSkillRule.maximumRuleCount
    ) async throws -> [StandingSkillRule] {
        guard (1...StandingSkillRule.maximumRuleCount).contains(limit) else {
            return []
        }
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, skillID, skillVersion, trigger,
                           subjectPredicate, action,
                           maximumDailyExecutions, isEnabled,
                           createdAt, updatedAt
                    FROM standingSkillRule
                    ORDER BY createdAt ASC, id ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.standingSkillRule(from:))
        }
    }

    /// Inserts exactly one new rule. The closed trigger/predicate/action tuple
    /// is unique; an existing tuple returns false without mutating it.
    public func insertStandingSkillRule(
        _ rule: StandingSkillRule
    ) async throws -> StandingSkillRuleInsertionOutcome {
        guard rule.isValid else {
            throw StorageError.invalidStandingSkillRule("invalid input")
        }
        return try await database.write { database in
            let duplicate = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM standingSkillRule
                        WHERE trigger = ?
                          AND subjectPredicate = ?
                          AND action = ?
                    )
                    """,
                arguments: [
                    rule.trigger.rawValue,
                    rule.subjectPredicate.rawValue,
                    rule.action.rawValue
                ]) ?? false
            if duplicate { return .duplicate }
            let count = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM standingSkillRule") ?? 0
            guard count < StandingSkillRule.maximumRuleCount else {
                return .capacityReached
            }
            try database.execute(
                sql: """
                    INSERT INTO standingSkillRule (
                        id, skillID, skillVersion, trigger,
                        subjectPredicate, action,
                        maximumDailyExecutions, isEnabled,
                        createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rule.id.rawValue.uuidString,
                    rule.skillID,
                    rule.skillVersion,
                    rule.trigger.rawValue,
                    rule.subjectPredicate.rawValue,
                    rule.action.rawValue,
                    rule.maximumDailyExecutions,
                    rule.isEnabled,
                    rule.createdAt,
                    rule.updatedAt
                ])
            guard database.changesCount == 1 else {
                throw StorageError.invalidStandingSkillRule(
                    "insert did not persist one row")
            }
            return .inserted
        }
    }

    public func setStandingSkillRule(
        _ id: StandingSkillRuleID,
        isEnabled: Bool,
        at timestamp: Date = Date()
    ) async throws -> Bool {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageError.invalidStandingSkillRule("invalid timestamp")
        }
        return try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE standingSkillRule
                    SET isEnabled = ?, updatedAt = MAX(updatedAt, ?)
                    WHERE id = ?
                    """,
                arguments: [
                    isEnabled,
                    timestamp,
                    id.rawValue.uuidString
                ])
            return database.changesCount == 1
        }
    }

    public func deleteStandingSkillRule(
        _ id: StandingSkillRuleID
    ) async throws -> Bool {
        try await database.write { database in
            try database.execute(
                sql: "DELETE FROM standingSkillRule WHERE id = ?",
                arguments: [id.rawValue.uuidString])
            return database.changesCount == 1
        }
    }

    private static func standingSkillRule(
        from row: Row
    ) throws -> StandingSkillRule {
        let rawID: String = row["id"]
        guard let uuid = UUID(uuidString: rawID) else {
            throw StorageError.invalidPersistedUUID(
                table: "standingSkillRule",
                column: "id",
                value: rawID)
        }
        let rawTrigger: String = row["trigger"]
        let rawPredicate: String = row["subjectPredicate"]
        let rawAction: String = row["action"]
        guard let trigger = StandingSkillRuleTrigger(rawValue: rawTrigger),
              let predicate = StandingSkillRuleSubjectPredicate(
                  rawValue: rawPredicate),
              let action = StandingSkillRuleAction(rawValue: rawAction)
        else {
            throw StorageError.invalidStandingSkillRule(
                "unknown trigger, predicate, or action")
        }
        let rule = StandingSkillRule(
            id: StandingSkillRuleID(rawValue: uuid),
            skillID: row["skillID"],
            skillVersion: row["skillVersion"],
            trigger: trigger,
            subjectPredicate: predicate,
            action: action,
            maximumDailyExecutions: row["maximumDailyExecutions"],
            isEnabled: row["isEnabled"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"])
        guard rule.isValid else {
            throw StorageError.invalidStandingSkillRule("invalid persisted row")
        }
        return rule
    }
}
