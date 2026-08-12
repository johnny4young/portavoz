import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    public static let maximumRecentSkillExecutionCount = 100

    /// Reads the complete device policy. Missing or corrupt singleton state is
    /// a storage failure, never an implicit permission to execute.
    public func skillExecutionPolicy() async throws -> SkillExecutionPolicy {
        try await database.read { database in
            guard let isPaused = try Bool.fetchOne(
                database,
                sql: "SELECT isPaused FROM skillControl WHERE id = 1")
            else {
                throw StorageError.invalidPersistedValue(
                    table: "skillControl",
                    column: "id",
                    value: "missing singleton")
            }
            let disabled = try Set(String.fetchAll(
                database,
                sql: "SELECT skillID FROM skillDisablement ORDER BY skillID"))
            return SkillExecutionPolicy(
                isPaused: isPaused,
                disabledSkillIDs: disabled)
        }
    }

    public func setAllSkillsPaused(
        _ isPaused: Bool,
        at timestamp: Date = Date()
    ) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillControl
                    SET isPaused = ?, updatedAt = MAX(updatedAt, ?)
                    WHERE id = 1
                    """,
                arguments: [isPaused, timestamp])
            guard database.changesCount == 1 else {
                throw StorageError.invalidPersistedValue(
                    table: "skillControl",
                    column: "id",
                    value: "missing singleton")
            }
        }
    }

    public func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date = Date()
    ) async throws {
        guard skillID == skillID.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillID.isEmpty,
              skillID.count <= 80
        else {
            throw StorageError.invalidPersistedValue(
                table: "skillDisablement",
                column: "skillID",
                value: skillID)
        }
        try await database.write { database in
            if isEnabled {
                try database.execute(
                    sql: "DELETE FROM skillDisablement WHERE skillID = ?",
                    arguments: [skillID])
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO skillDisablement (skillID, disabledAt)
                        VALUES (?, ?)
                        ON CONFLICT(skillID) DO UPDATE SET
                            disabledAt = MAX(disabledAt, excluded.disabledAt)
                        """,
                    arguments: [skillID, timestamp])
            }
        }
    }

    /// Newest content-free execution projections, bounded before materializing
    /// Swift values. Invalid limits return no authority rather than widening
    /// into an unbounded read.
    public func recentSkillExecutions(
        limit: Int
    ) async throws -> [SkillExecutionRecord] {
        try await skillExecutions(scope: .recent, limit: limit)
    }

    /// Newest content-free execution projections for one review scope.
    /// Every query is bounded before decoding and its predicate matches one
    /// newest-first partial index from schema v39. `needsAttention` uses a
    /// negative terminal/waiting predicate so unknown future states remain
    /// visible for review instead of disappearing fail-open.
    public func skillExecutions(
        scope: SkillExecutionReviewScope,
        limit: Int
    ) async throws -> [SkillExecutionRecord] {
        guard (1...Self.maximumRecentSkillExecutionCount).contains(limit)
        else { return [] }
        return try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, failureCategory, attempt, updatedAt
                    FROM skillExecutionState INDEXED BY
                         \(Self.skillExecutionReviewIndex(scope))
                    \(Self.skillExecutionReviewPredicate(scope))
                    ORDER BY updatedAt DESC, proposalID ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.skillExecutionRecord(from:))
        }
    }

    private static func skillExecutionReviewPredicate(
        _ scope: SkillExecutionReviewScope
    ) -> String {
        switch scope {
        case .recent:
            ""
        case .waiting:
            "WHERE state = 'confirmed'"
        case .needsAttention:
            "WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')"
        case .completed:
            "WHERE state IN ('succeeded', 'cancelled')"
        }
    }

    private static func skillExecutionReviewIndex(
        _ scope: SkillExecutionReviewScope
    ) -> String {
        switch scope {
        case .recent:
            "skillExecutionState_on_recent"
        case .waiting:
            "skillExecutionState_on_waiting"
        case .needsAttention:
            "skillExecutionState_on_attention"
        case .completed:
            "skillExecutionState_on_completed"
        }
    }
}
