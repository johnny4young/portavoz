import GRDB
import PortavozCore

extension StorageSchema {
    /// v47: immutable standing-rule authority receipts plus one bounded local
    /// artifact. The receipt intentionally snapshots `ruleID` without a
    /// foreign key so deleting the current rule cannot erase its history.
    static func registerStandingSkillExecutionMigration(
        in migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v47") { database in
            try database.create(
                table: "standingSkillExecutionAuthority"
            ) { table in
                table.primaryKey("proposalID", .text)
                    .references("skillExecutionState", onDelete: .cascade)
                table.column("ruleID", .text).notNull().check(
                    sql: "length(ruleID) = 36")
                table.column("action", .text).notNull().check(
                    sql: "action = 'prepare-pre-meeting-brief'")
                table.column("occurrenceFingerprint", .text).notNull().check(
                    sql: "length(occurrenceFingerprint) = 64")
                table.column("eventStartAt", .datetime).notNull()
                table.column("budgetWindowStart", .datetime).notNull()
                table.column("budgetWindowEnd", .datetime).notNull()
                table.column("authorizedAt", .datetime).notNull()
                table.check(sql: "budgetWindowEnd > budgetWindowStart")
                table.check(sql: "authorizedAt >= budgetWindowStart")
                table.check(sql: "authorizedAt < budgetWindowEnd")
                table.uniqueKey(["action", "occurrenceFingerprint"])
            }
            try database.create(
                index: "standingSkillExecutionAuthority_on_daily_budget",
                on: "standingSkillExecutionAuthority",
                columns: ["ruleID", "authorizedAt"])
            try database.execute(sql: """
                CREATE TRIGGER standingSkillExecutionAuthority_no_update
                BEFORE UPDATE ON standingSkillExecutionAuthority
                BEGIN
                    SELECT RAISE(ABORT, 'standing authority is immutable');
                END
                """)

            try database.create(table: "standingSkillArtifact") { table in
                table.primaryKey("proposalID", .text)
                    .references("skillExecutionState", onDelete: .cascade)
                table.column("kind", .text).notNull().check(
                    sql: "kind = 'pre-meeting-brief'")
                table.column("formatVersion", .integer).notNull().check(
                    sql: "formatVersion = \(StandingSkillArtifact.currentFormatVersion)")
                table.column("payload", .blob).notNull().check(sql: """
                    length(payload) BETWEEN 1 AND
                        \(StandingSkillArtifact.maximumPayloadByteCount)
                    """)
                table.column("sha256", .text).notNull().check(
                    sql: "length(sha256) = 64")
                table.column("createdAt", .datetime).notNull()
            }
            try database.execute(sql: """
                CREATE TRIGGER standingSkillArtifact_no_update
                BEFORE UPDATE ON standingSkillArtifact
                BEGIN
                    SELECT RAISE(ABORT, 'standing artifact is immutable');
                END
                """)
        }
    }
}
